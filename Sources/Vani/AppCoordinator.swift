import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import VaniCore

@MainActor
final class AppCoordinator: ObservableObject {
  @Published private(set) var snapshot: SessionSnapshot = .initial
  @Published private(set) var microphonePermission: PermissionState = .unknown
  @Published private(set) var accessibilityPermission: PermissionState = .denied
  @Published private(set) var modelInstalled = false
  @Published private(set) var diagnostics: [DiagnosticEvent] = []
  @Published private(set) var history: [TranscriptHistoryEntry] = []
  @Published private(set) var settingsError: String?
  @Published var settings: VaniSettings = .default

  private let settingsStore: SettingsStore
  private let historyStore: TranscriptHistoryStore
  private let diagnosticStore: DiagnosticStore
  private let session: DictationSession
  private let hotkeyMonitor = GlobalHotkeyMonitor()
  private let overlay = OverlayController()
  private var notificationTokens: [NSObjectProtocol] = []
  private var qaWindow: NSWindow?
  private var settingsRevision: UInt64 = 0
  private var started = false

  init() {
    let focusProvider = SystemFocusProvider()
    let historyStore = TranscriptHistoryStore()
    let diagnosticStore = DiagnosticStore.shared
    settingsStore = SettingsStore()
    self.historyStore = historyStore
    self.diagnosticStore = diagnosticStore
    session = DictationSession(
      audioCapture: AVAudioEngineCapture(),
      speechRecognizer: FluidAudioSpeechRecognizer(),
      textInserter: SystemTextInserter(focusProvider: focusProvider),
      focusProvider: focusProvider,
      history: historyStore,
      diagnostics: diagnosticStore
    )

    Task { [weak self] in
      await self?.start()
    }
  }

  var menuBarIconName: String {
    switch snapshot.phase {
    case .listening: "waveform.circle.fill"
    case .transcribing, .inserting, .preparing: "waveform.badge.magnifyingglass"
    case .recoverableError: "exclamationmark.circle.fill"
    case .setup: "waveform.circle"
    case .ready: "waveform"
    case .disabled: "waveform.slash"
    }
  }

  var canDictate: Bool {
    snapshot.phase == .ready
      && microphonePermission.isGranted
      && accessibilityPermission.isGranted
  }

  var setupIncomplete: Bool {
    !microphonePermission.isGranted
      || !accessibilityPermission.isGranted
      || !modelInstalled
  }

  func start() async {
    guard !started else { return }
    started = true
    settings = await settingsStore.load()
    await session.updateSettings(settings)
    await session.setObserver { [weak self] snapshot in
      Task { @MainActor in
        self?.apply(snapshot)
      }
    }

    hotkeyMonitor.onPress = { [weak self] in
      self?.beginDictation()
    }
    hotkeyMonitor.onRelease = { [weak self] in
      self?.endDictation()
    }
    installSystemObservers()
    showQAWindowIfRequested()
    await refreshPermissions()
    modelInstalled = await session.modelsAreInstalled()
    if modelInstalled, microphonePermission.isGranted {
      _ = await session.prepareModels(allowDownload: false)
    }
    configureHotkey()
    await refreshHistory()
  }

  func requestMicrophonePermission() {
    Task {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
      await refreshPermissions()
      await prepareWhenPossible()
    }
  }

  func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    openPrivacyPane("Privacy_Accessibility")
    Task {
      for _ in 0..<30 where !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await refreshPermissions()
        if accessibilityPermission.isGranted {
          configureHotkey()
          await prepareWhenPossible()
          return
        }
      }
    }
  }

  func downloadModel() {
    Task {
      _ = await session.prepareModels(allowDownload: true)
      modelInstalled = await session.modelsAreInstalled()
      await prepareWhenPossible()
    }
  }

  func retry() {
    Task { await session.retry() }
  }

  func performPrimaryRecoveryAction() {
    switch snapshot.failure?.recoveryAction {
    case .openMicrophoneSettings:
      requestMicrophonePermission()
    case .openAccessibilitySettings:
      requestAccessibilityPermission()
    case .retryPreparation, .retryTranscription, .retryInsertion:
      retry()
    case .copyTranscript:
      copyRecoveredTranscript()
    case .startAgain:
      discardRecovery()
    case .some(.none), nil:
      break
    }
  }

  var primaryRecoveryLabel: String? {
    switch snapshot.failure?.recoveryAction {
    case .openMicrophoneSettings: "Allow Microphone"
    case .openAccessibilitySettings: "Allow Accessibility"
    case .retryPreparation, .retryTranscription, .retryInsertion: "Retry"
    case .copyTranscript: "Copy"
    case .startAgain: "Start Again"
    case .some(.none), nil: nil
    }
  }

  var primaryRecoveryIcon: String {
    switch snapshot.failure?.recoveryAction {
    case .openMicrophoneSettings, .openAccessibilitySettings: "gearshape"
    case .copyTranscript: "doc.on.doc"
    case .startAgain: "arrow.counterclockwise"
    default: "arrow.clockwise"
    }
  }

  func copyRecoveredTranscript() {
    Task {
      do {
        try await session.copyRecoveredTranscript()
      } catch {
        settingsError = (error as? VaniFailure)?.message ?? "Could not copy transcript."
      }
    }
  }

  func discardRecovery() {
    Task { await session.discardRecovery() }
  }

  func setShortcut(_ shortcut: HoldShortcut) {
    settings.shortcut = shortcut
    persistSettings()
    configureHotkey()
  }

  func setHistoryEnabled(_ enabled: Bool) {
    settings.historyEnabled = enabled
    persistSettings()
    Task { await refreshHistory() }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      settings.launchAtLogin = enabled
      settingsError = nil
      persistSettings()
    } catch {
      settingsError = "Launch at login requires the bundled Vani app."
    }
  }

  func addDictionaryEntry(spoken: String, replacement: String) {
    let entry = DictionaryEntry(spoken: spoken, replacement: replacement)
    guard entry.isValid else { return }
    settings.dictionary.append(entry)
    persistSettings()
  }

  func removeDictionaryEntries(at offsets: IndexSet) {
    settings.dictionary.remove(atOffsets: offsets)
    persistSettings()
  }

  func refreshDiagnostics() {
    Task {
      diagnostics = await diagnosticStore.snapshot().reversed()
    }
  }

  func clearDiagnostics() {
    Task {
      await diagnosticStore.clear()
      diagnostics = []
    }
  }

  func clearHistory() {
    Task {
      try? await historyStore.clear()
      history = []
    }
  }

  private func beginDictation() {
    guard canDictate else { return }
    Task { await session.beginDictation() }
  }

  private func endDictation() {
    Task {
      await session.endDictation()
      await refreshHistory()
    }
  }

  private func apply(_ newSnapshot: SessionSnapshot) {
    let previous = snapshot.phase
    snapshot = newSnapshot
    overlay.update(snapshot: newSnapshot, previousPhase: previous)
  }

  private func persistSettings() {
    let settings = settings
    settingsRevision &+= 1
    let revision = settingsRevision
    Task {
      do {
        let saved = try await settingsStore.save(settings, revision: revision)
        guard saved else { return }
        await session.updateSettings(settings)
        if revision == settingsRevision {
          settingsError = nil
        }
      } catch {
        if revision == settingsRevision {
          settingsError = "Settings could not be saved."
        }
      }
    }
  }

  private func refreshPermissions() async {
    let previousMicrophone = microphonePermission
    let previousAccessibility = accessibilityPermission
    let currentMicrophone = PermissionState.microphone
    let currentAccessibility = PermissionState.accessibility

    microphonePermission = currentMicrophone
    accessibilityPermission = currentAccessibility

    if previousMicrophone.isGranted, !currentMicrophone.isGranted {
      await session.permissionWasRevoked(.microphonePermissionDenied)
    } else if previousAccessibility.isGranted, !currentAccessibility.isGranted {
      await session.permissionWasRevoked(.accessibilityPermissionDenied)
    }

    if !accessibilityPermission.isGranted {
      hotkeyMonitor.stop()
    }
  }

  private func prepareWhenPossible() async {
    modelInstalled = await session.modelsAreInstalled()
    guard microphonePermission.isGranted, modelInstalled else { return }
    if snapshot.phase == .setup || snapshot.phase == .recoverableError {
      _ = await session.prepareModels(allowDownload: false)
    }
  }

  private func configureHotkey() {
    guard accessibilityPermission.isGranted else {
      hotkeyMonitor.stop()
      return
    }
    do {
      try hotkeyMonitor.start(shortcut: settings.shortcut)
      settingsError = nil
    } catch {
      settingsError = "The global shortcut could not start. Recheck Accessibility permission."
    }
  }

  private func refreshHistory() async {
    guard settings.historyEnabled else {
      history = []
      return
    }
    history = (try? await historyStore.load()) ?? []
  }

  private func installSystemObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    notificationTokens.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { await self?.session.systemWillSleep() }
      }
    )
    notificationTokens.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.refreshPermissions()
          await self?.session.resumeAfterSystemChange()
          await self?.prepareWhenPossible()
        }
      }
    )
    notificationTokens.append(
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.session.audioRouteDidChange()
          try? await Task.sleep(for: .milliseconds(300))
          await self?.session.resumeAfterSystemChange()
        }
      }
    )
  }

  private func openPrivacyPane(_ pane: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func showQAWindowIfRequested() {
    guard ProcessInfo.processInfo.environment["VANI_QA_WINDOW"] == "1" else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Vani QA"
    window.contentViewController = NSHostingController(
      rootView: MenuContentView().environmentObject(self)
    )
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    qaWindow = window
  }
}

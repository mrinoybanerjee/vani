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
  @Published private(set) var inputMonitoringPermission: PermissionState = .denied
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
      && inputMonitoringPermission.isGranted
  }

  var setupIncomplete: Bool {
    !microphonePermission.isGranted
      || !accessibilityPermission.isGranted
      || !inputMonitoringPermission.isGranted
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
    hotkeyMonitor.onPasteLast = { [weak self] in
      self?.pasteLastTranscript()
    }
    hotkeyMonitor.onCopyLast = { [weak self] in
      self?.copyLastTranscript()
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
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      Task {
        await refreshPermissions()
        await prepareWhenPossible()
      }
    case .notDetermined:
      Task {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await refreshPermissions()
        await prepareWhenPossible()
      }
    case .denied:
      openPrivacyPane("Privacy_Microphone")
    case .restricted:
      settingsError = "Microphone access is restricted by macOS."
    @unknown default:
      settingsError = "Microphone permission could not be determined."
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

  func requestInputMonitoringPermission() {
    _ = CGRequestListenEventAccess()
    openPrivacyPane("Privacy_ListenEvent")
    Task {
      for _ in 0..<30 where !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await refreshPermissions()
        if inputMonitoringPermission.isGranted {
          configureHotkey()
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
    case .openInputMonitoringSettings:
      requestInputMonitoringPermission()
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
    case .openInputMonitoringSettings: "Allow Input Monitoring"
    case .retryPreparation, .retryTranscription, .retryInsertion: "Retry"
    case .copyTranscript: "Copy Transcript"
    case .startAgain: "Start Again"
    case .some(.none), nil: nil
    }
  }

  var primaryRecoveryIcon: String {
    switch snapshot.failure?.recoveryAction {
    case .openMicrophoneSettings, .openAccessibilitySettings, .openInputMonitoringSettings:
      "gearshape"
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

  func pasteLastTranscript() {
    guard snapshot.phase == .ready, snapshot.hasLastTranscript else { return }
    Task { await session.pasteLastTranscript() }
  }

  func copyLastTranscript() {
    guard snapshot.phase == .ready, snapshot.hasLastTranscript else { return }
    Task {
      do {
        try await session.copyLastTranscript()
        overlay.showLastTranscriptCopied()
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

  func setSmartFormattingEnabled(_ enabled: Bool) {
    settings.smartFormattingEnabled = enabled
    persistSettings()
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
      recordDiagnostic(category: .storage, code: "launch_at_login_failed")
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

  @discardableResult
  func addSnippet(trigger: String, expansion: String) -> Bool {
    let entry = SnippetEntry(trigger: trigger, expansion: expansion)
    guard settings.snippets.count < VaniSettings.maximumSnippetCount else {
      settingsError = "Vani supports up to 200 snippets."
      return false
    }
    if let validationError = snippetValidationError(for: entry) {
      settingsError = validationError
      return false
    }

    settings.snippets.append(
      SnippetEntry(trigger: entry.normalizedTrigger, expansion: entry.expansion)
    )
    persistSettings()
    return true
  }

  @discardableResult
  func updateSnippet(id: UUID, trigger: String, expansion: String) -> Bool {
    guard let index = settings.snippets.firstIndex(where: { $0.id == id }) else {
      settingsError = "That snippet no longer exists."
      return false
    }

    let entry = SnippetEntry(id: id, trigger: trigger, expansion: expansion)
    if let validationError = snippetValidationError(for: entry, excludingID: id) {
      settingsError = validationError
      return false
    }

    settings.snippets[index] = SnippetEntry(
      id: id,
      trigger: entry.normalizedTrigger,
      expansion: entry.expansion
    )
    persistSettings()
    return true
  }

  func removeSnippets(at offsets: IndexSet) {
    settings.snippets.remove(atOffsets: offsets)
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
      do {
        try await historyStore.clear()
        history = []
        settingsError = nil
      } catch {
        settingsError = "Transcript history could not be cleared."
        recordDiagnostic(category: .storage, code: "history_clear_failed")
      }
    }
  }

  func dismissSettingsError() {
    settingsError = nil
  }

  private func snippetValidationError(
    for entry: SnippetEntry,
    excludingID: UUID? = nil
  ) -> String? {
    guard entry.isValid else {
      return "Snippet triggers must be 1-100 characters; text can be up to 4,000."
    }

    let normalizedTrigger = entry.normalizedTrigger.lowercased()
    if settings.snippets.contains(where: {
      $0.id != excludingID && $0.normalizedTrigger.lowercased() == normalizedTrigger
    }) {
      return "That snippet trigger is already in use."
    }
    if settings.dictionary.contains(where: {
      SnippetEntry(trigger: $0.spoken, expansion: "x").normalizedTrigger.lowercased()
        == normalizedTrigger
    }) {
      return "That phrase is already used by the dictionary."
    }
    return nil
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
        recordDiagnostic(category: .storage, code: "settings_save_failed")
      }
    }
  }

  private func refreshPermissions() async {
    let previousMicrophone = microphonePermission
    let previousAccessibility = accessibilityPermission
    let previousInputMonitoring = inputMonitoringPermission
    let currentMicrophone = PermissionState.microphone
    let currentAccessibility = PermissionState.accessibility
    let currentInputMonitoring = PermissionState.inputMonitoring

    microphonePermission = currentMicrophone
    accessibilityPermission = currentAccessibility
    inputMonitoringPermission = currentInputMonitoring

    if previousMicrophone.isGranted, !currentMicrophone.isGranted {
      await session.permissionWasRevoked(.microphonePermissionDenied)
    } else if previousAccessibility.isGranted, !currentAccessibility.isGranted {
      await session.permissionWasRevoked(.accessibilityPermissionDenied)
    } else if previousInputMonitoring.isGranted, !currentInputMonitoring.isGranted {
      await session.permissionWasRevoked(.inputMonitoringPermissionDenied)
    }

    if currentMicrophone.isGranted, currentAccessibility.isGranted,
      currentInputMonitoring.isGranted,
      !previousMicrophone.isGranted || !previousAccessibility.isGranted
        || !previousInputMonitoring.isGranted
    {
      await session.permissionsWereRestored()
    }

    if !accessibilityPermission.isGranted || !inputMonitoringPermission.isGranted {
      hotkeyMonitor.stop()
    }
  }

  private func prepareWhenPossible() async {
    modelInstalled = await session.modelsAreInstalled()
    guard microphonePermission.isGranted, modelInstalled else { return }
    let current = await session.snapshot()
    if current.phase == .setup
      || (current.phase == .recoverableError
        && current.failure?.recoveryAction == .retryPreparation)
    {
      _ = await session.prepareModels(allowDownload: false)
    }
  }

  private func configureHotkey() {
    guard accessibilityPermission.isGranted, inputMonitoringPermission.isGranted else {
      hotkeyMonitor.stop()
      return
    }
    do {
      try hotkeyMonitor.start(shortcut: settings.shortcut)
      settingsError = nil
    } catch {
      settingsError = "The global shortcut could not start. Recheck Input Monitoring."
      recordDiagnostic(category: .permission, code: "hotkey_monitor_start_failed")
    }
  }

  private func refreshHistory() async {
    guard settings.historyEnabled else {
      history = []
      return
    }
    do {
      history = try await historyStore.load()
    } catch {
      history = []
      settingsError = "Unreadable transcript history was quarantined."
      recordDiagnostic(category: .storage, code: "history_load_failed")
    }
  }

  private func recordDiagnostic(category: DiagnosticCategory, code: String) {
    VaniLog.event(category: category, code: code)
    Task {
      await diagnosticStore.record(DiagnosticEvent(category: category, code: code))
    }
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
    notificationTokens.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.refreshPermissions()
          self?.configureHotkey()
          await self?.prepareWhenPossible()
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

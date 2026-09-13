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
  @Published private(set) var personalizationModelInstalled = false
  @Published private(set) var personalizationModelProgress: Double?
  @Published private(set) var diagnostics: [DiagnosticEvent] = []
  @Published private(set) var history: [TranscriptHistoryEntry] = []
  @Published private(set) var learnedCorrections: [LearnedCorrection] = []
  @Published private(set) var hasStoredHistoryData = false
  @Published private(set) var settingsError: String?
  @Published var settings: VaniSettings = .default

  private let settingsStore: SettingsStore
  private let historyStore: TranscriptHistoryStore
  private let diagnosticStore: DiagnosticStore
  private let personalizationStore: PersonalizationStore
  private let speechRecognizer: FluidAudioSpeechRecognizer
  @Published private(set) var meetingOwnsSpeech = false
  private var meetingWindowController: MeetingWindowController?
  private let session: DictationSession
  private let hotkeyMonitor = GlobalHotkeyMonitor()
  private let overlay = OverlayController()
  private let cuePlayer = DictationCuePlayer()
  private let teachWindowController = TeachWindowController()
  private var notesWindowController: NotesWindowController?
  private var notificationTokens: [NSObjectProtocol] = []
  private var qaWindow: NSWindow?
  private var captureStartTask: Task<Void, Never>?
  private var sessionOperationTask: Task<Void, Never>?
  private var captureStartGeneration: UInt64 = 0
  private var sessionOperationGeneration: UInt64 = 0
  private var historyRevision: UInt64 = 0
  private var settingsRevision: UInt64 = 0
  private var personalizationRevision: UInt64 = 0
  private var startCueWasPreplayed = false
  private var isTerminating = false
  private var quitPreflight = false
  private var started = false

  init(startAutomatically: Bool = true) {
    let focusProvider = SystemFocusProvider()
    let historyStore = TranscriptHistoryStore()
    let diagnosticStore = DiagnosticStore.shared
    let personalizationStore = PersonalizationStore()
    settingsStore = SettingsStore()
    self.historyStore = historyStore
    self.diagnosticStore = diagnosticStore
    self.personalizationStore = personalizationStore
    let speechRecognizer = FluidAudioSpeechRecognizer()
    self.speechRecognizer = speechRecognizer
    session = DictationSession(
      audioCapture: AVAudioEngineCapture(),
      speechRecognizer: speechRecognizer,
      textInserter: SystemTextInserter(focusProvider: focusProvider),
      focusProvider: focusProvider,
      history: historyStore,
      diagnostics: diagnosticStore
    )
    if startAutomatically {
      AppDelegate.coordinator = self
      Task { [weak self] in
        await self?.start()
      }
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
      && !meetingOwnsSpeech
      && !quitPreflight
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
    do {
      learnedCorrections = try await personalizationStore.load()
    } catch {
      learnedCorrections = []
      settingsError = "Unreadable personalization data was quarantined."
      recordDiagnostic(category: .storage, code: "personalization_load_failed")
    }
    await session.updateSettings(settings)
    await session.updatePersonalization(learnedCorrections)
    await session.setObserver { [weak self] snapshot in
      self?.apply(snapshot)
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
    await refreshPermissions()
    modelInstalled = await session.modelsAreInstalled()
    personalizationModelInstalled = await session.personalizationModelsAreInstalled()
    if modelInstalled, microphonePermission.isGranted {
      _ = await session.prepareModels(allowDownload: false)
    }
    configureHotkey()
    await refreshHistory()
    AppDelegate.coordinatorDidBecomeReady()
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

  func downloadPersonalizationModel() {
    guard personalizationModelProgress == nil else { return }
    personalizationModelProgress = 0
    Task {
      do {
        try await session.preparePersonalizationModels { [weak self] progress in
          Task { @MainActor in
            self?.personalizationModelProgress = min(max(progress, 0), 1)
          }
        }
        personalizationModelInstalled = await session.personalizationModelsAreInstalled()
        settingsError = nil
      } catch {
        personalizationModelInstalled = await session.personalizationModelsAreInstalled()
        settingsError = "The optional personalization model could not be installed."
        recordDiagnostic(category: .storage, code: "personalization_model_install_failed")
      }
      personalizationModelProgress = nil
    }
  }

  func retry() {
    performSessionOperation { coordinator in
      await coordinator.session.retry()
    }
  }

  func performPrimaryRecoveryAction() {
    switch snapshot.failure?.recoveryAction {
    case .openMicrophoneSettings:
      requestMicrophonePermission()
    case .openAccessibilitySettings:
      requestAccessibilityPermission()
    case .openInputMonitoringSettings:
      requestInputMonitoringPermission()
    case .retryPreparation, .retryAudioFinalization, .retryTranscription, .retryInsertion:
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
    case .retryPreparation, .retryAudioFinalization, .retryTranscription, .retryInsertion:
      "Retry"
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
    performSessionOperation { coordinator in
      await coordinator.session.pasteLastTranscript()
    }
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

  func quit() {
    NSApplication.shared.terminate(nil)
  }

  func showMeetings() {
    if meetingWindowController == nil {
      let model = MeetingModel(
        recognizer: speechRecognizer,
        reserveSpeech: { [weak self] in
          guard let self, !meetingOwnsSpeech, snapshot.phase == .ready,
            captureStartTask == nil, sessionOperationTask == nil, !isTerminating, !quitPreflight
          else { return false }
          meetingOwnsSpeech = true
          return true
        }, releaseSpeech: { [weak self] in self?.meetingOwnsSpeech = false })
      meetingWindowController = MeetingWindowController(model: model)
    }
    meetingWindowController?.present()
  }

  func showNotes(saveLastTranscript: Bool = false) {
    if notesWindowController == nil { notesWindowController = NotesWindowController() }
    guard let controller = notesWindowController else { return }
    controller.present(load: !saveLastTranscript)
    if saveLastTranscript {
      Task {
        guard let text = await session.transcriptForNote() else { return }
        await controller.model.create(text: text)
      }
    }
  }

  func saveNotesBeforeTermination() async -> Bool {
    quitPreflight = true
    var accepted = false
    defer { if !accepted { quitPreflight = false } }
    if let meetingWindowController, !(await meetingWindowController.model.prepareToQuit()) {
      meetingWindowController.present()
      return false
    }
    guard let controller = notesWindowController else {
      accepted = true
      return true
    }
    let saved = await controller.model.save()
    if !saved { controller.present() }
    accepted = saved
    return saved
  }

  func prepareForTermination() async {
    guard !isTerminating else { return }
    isTerminating = true
    hotkeyMonitor.stop()
    let captureTask = captureStartTask
    let operationTask = sessionOperationTask
    captureTask?.cancel()
    operationTask?.cancel()
    await session.terminate()
    captureStartTask = nil
    sessionOperationTask = nil
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

  func setSoundFeedbackEnabled(_ enabled: Bool) {
    settings.soundFeedbackEnabled = enabled
    persistSettings()
  }

  func setPersonalizationEnabled(_ enabled: Bool) {
    settings.personalizationEnabled = enabled
    persistSettings()
  }

  func correctionCandidate() async -> CorrectionCandidate? {
    await session.correctionCandidate()
  }

  func prepareToShowTeachWindow() {
    teachWindowController.requestActivation()
  }

  func showTeachWindow(for candidate: CorrectionCandidate) {
    teachWindowController.present(candidate: candidate, coordinator: self)
  }

  func learnCorrection(
    original: String,
    corrected: String,
    applicationBundleIdentifier: String?
  ) async -> Bool {
    personalizationRevision &+= 1
    let revision = personalizationRevision
    do {
      let result = try await personalizationStore.learn(
        original: original,
        corrected: corrected,
        applicationBundleIdentifier: applicationBundleIdentifier
      )
      guard !result.learned.isEmpty else {
        if revision == personalizationRevision {
          settingsError = "That edit did not contain a reusable correction."
        }
        return false
      }
      guard revision == personalizationRevision else { return false }
      learnedCorrections = result.corrections
      settings.personalizationEnabled = true
      persistSettings()
      await session.updatePersonalization(learnedCorrections)
      return true
    } catch {
      if revision == personalizationRevision {
        settingsError = "Vani could not save that correction."
      }
      recordDiagnostic(category: .storage, code: "personalization_save_failed")
      return false
    }
  }

  func removeLearnedCorrections(at offsets: IndexSet) {
    let ids = Set(
      offsets.compactMap { index in
        learnedCorrections.indices.contains(index) ? learnedCorrections[index].id : nil
      })
    guard !ids.isEmpty else { return }
    personalizationRevision &+= 1
    let revision = personalizationRevision
    Task {
      do {
        let updated = try await personalizationStore.remove(ids: ids)
        guard revision == personalizationRevision else { return }
        learnedCorrections = updated
        await session.updatePersonalization(updated)
      } catch {
        guard revision == personalizationRevision else { return }
        settingsError = "Vani could not delete that learned correction."
        recordDiagnostic(category: .storage, code: "personalization_delete_failed")
      }
    }
  }

  func clearLearnedCorrections() {
    personalizationRevision &+= 1
    let revision = personalizationRevision
    Task {
      do {
        try await personalizationStore.clear()
        guard revision == personalizationRevision else { return }
        learnedCorrections = []
        await session.updatePersonalization([])
      } catch {
        guard revision == personalizationRevision else { return }
        settingsError = "Vani could not reset its learned corrections."
        recordDiagnostic(category: .storage, code: "personalization_clear_failed")
      }
    }
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

  @discardableResult
  func addDictionaryEntry(spoken: String, replacement: String) -> Bool {
    let entry = DictionaryEntry(spoken: spoken, replacement: replacement)
    guard settings.dictionary.count < VaniSettings.maximumDictionaryEntryCount else {
      settingsError =
        "Vani supports up to \(VaniSettings.maximumDictionaryEntryCount) dictionary entries."
      return false
    }
    guard entry.isValid else {
      settingsError =
        "Spoken phrases must be 1-\(DictionaryEntry.maximumSpokenLength) characters; "
        + "replacements can be up to \(DictionaryEntry.maximumReplacementLength)."
      return false
    }

    let normalizedSpoken = entry.normalizedSpoken.lowercased()
    if settings.dictionary.contains(where: {
      $0.normalizedSpoken.lowercased() == normalizedSpoken
    }) {
      settingsError = "That spoken phrase is already in the dictionary."
      return false
    }
    if settings.snippets.contains(where: {
      $0.normalizedTrigger.lowercased() == normalizedSpoken
    }) {
      settingsError = "That phrase is already used by a snippet."
      return false
    }

    settings.dictionary.append(
      DictionaryEntry(spoken: entry.normalizedSpoken, replacement: entry.replacement)
    )
    persistSettings()
    return true
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
    historyRevision &+= 1
    let revision = historyRevision
    Task {
      do {
        try await historyStore.clear()
        historyRevision &+= 1
        history = []
        hasStoredHistoryData = false
        settingsError = nil
      } catch {
        guard revision == historyRevision else { return }
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
      $0.normalizedSpoken.lowercased() == normalizedTrigger
    }) {
      return "That phrase is already used by the dictionary."
    }
    return nil
  }

  private func beginDictation() {
    guard canDictate, captureStartTask == nil else { return }
    captureStartGeneration &+= 1
    let generation = captureStartGeneration
    captureStartTask = Task { [weak self] in
      guard let self else { return }
      if settings.soundFeedbackEnabled {
        startCueWasPreplayed = true
        cuePlayer.play(.started)
        try? await Task.sleep(
          for: DictationCueWaveform.duration(for: .started) + .milliseconds(20)
        )
        guard !Task.isCancelled, generation == captureStartGeneration, canDictate else {
          startCueWasPreplayed = false
          captureStartTask = nil
          return
        }
      }
      await session.beginDictation()
      if snapshot.phase != .listening {
        startCueWasPreplayed = false
      }
      if generation == captureStartGeneration {
        captureStartTask = nil
      }
    }
  }

  private func endDictation() {
    let startTask = captureStartTask
    captureStartGeneration &+= 1
    let releaseGeneration = captureStartGeneration
    startTask?.cancel()
    performSessionOperation { coordinator in
      await startTask?.value
      if coordinator.captureStartGeneration == releaseGeneration {
        coordinator.captureStartTask = nil
      }
      guard !Task.isCancelled else { return }
      await coordinator.session.endDictation()
    }
  }

  private func performSessionOperation(
    _ operation: @escaping @MainActor (AppCoordinator) async -> Void
  ) {
    guard !isTerminating, sessionOperationTask == nil else { return }
    sessionOperationGeneration &+= 1
    let generation = sessionOperationGeneration
    sessionOperationTask = Task { [weak self] in
      guard let self else { return }
      await operation(self)
      if generation == sessionOperationGeneration {
        sessionOperationTask = nil
      }
    }
  }

  private func apply(_ newSnapshot: SessionSnapshot) {
    let previous = snapshot.phase
    snapshot = newSnapshot
    overlay.update(snapshot: newSnapshot, previousPhase: previous)
    if let cue = DictationCueResolver.cue(
      previousPhase: previous,
      currentPhase: newSnapshot.phase,
      enabled: settings.soundFeedbackEnabled
    ) {
      if cue == .started, startCueWasPreplayed {
        startCueWasPreplayed = false
      } else {
        cuePlayer.play(cue)
      }
    }
    if previous == .inserting, newSnapshot.phase == .ready {
      Task { [weak self] in
        await self?.refreshHistory()
      }
    }
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
      await meetingWindowController?.model.interrupt(
        "Meeting stopped because microphone permission changed. Saved audio is available for recovery."
      )
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
    historyRevision &+= 1
    let revision = historyRevision
    do {
      let loadedHistory = try await historyStore.load()
      let hasStoredData =
        (try? await historyStore.hasStoredData()) ?? !loadedHistory.isEmpty
      guard revision == historyRevision else { return }
      history = loadedHistory
      hasStoredHistoryData = hasStoredData
    } catch VaniFailure.historyCorrupt {
      guard revision == historyRevision else { return }
      history = []
      hasStoredHistoryData = true
      settingsError = "Unreadable transcript history was quarantined."
      recordDiagnostic(category: .storage, code: "history_load_failed")
    } catch {
      let hasStoredData =
        (try? await historyStore.hasStoredData()) ?? true
      guard revision == historyRevision else { return }
      history = []
      hasStoredHistoryData = hasStoredData
      settingsError = "Transcript history could not be read or quarantined."
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
        Task { @MainActor in
          await self?.meetingWindowController?.model.interrupt(
            "Meeting stopped for sleep. Saved audio is available for recovery.")
          await self?.session.systemWillSleep()
        }
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

  func showQAWindowIfRequested() {
    guard
      let qaMode = QAWindowMode(
        environmentValue: ProcessInfo.processInfo.environment["VANI_QA_WINDOW"]
      )
    else { return }
    if qaMode == .teach {
      teachWindowController.present(
        candidate: TeachQAWindowFixture.candidate,
        save: TeachQAWindowFixture.save
      )
      return
    }
    let showsSettings = qaMode == .settings
    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: showsSettings ? 760 : 360,
        height: showsSettings ? 580 : 440
      ),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = showsSettings ? "Vani Settings QA" : "Vani QA"
    window.contentViewController = NSHostingController(
      rootView: AnyView(
        Group {
          if showsSettings {
            SettingsView()
          } else {
            MenuContentView()
          }
        }
        .environmentObject(self)
      )
    )
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    qaWindow = window
  }
}

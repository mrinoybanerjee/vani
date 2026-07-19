import Foundation

public actor DictationSession {
  public typealias Observer = @Sendable (SessionSnapshot) -> Void

  private let audioCapture: any AudioCapturing
  private let speechRecognizer: any SpeechRecognizing
  private let textInserter: any TextInserting
  private let focusProvider: any FocusProviding
  private let recovery: TranscriptRecovery
  private let history: TranscriptHistoryStore
  private let diagnostics: DiagnosticStore
  private let audioPolicy: AudioPolicy
  private let textPipeline: TextPipeline

  private var machine = SessionStateMachine()
  private var settings: VaniSettings
  private var failure: VaniFailure?
  private var modelProgress: Double?
  private var modelReady = false
  private var isPreparingModel = false
  private var isPreparingRequest = false
  private var preparationGeneration: UInt64 = 0
  private var isStartingCapture = false
  private var currentTarget: TextTarget?
  private var observer: Observer?

  public init(
    audioCapture: any AudioCapturing,
    speechRecognizer: any SpeechRecognizing,
    textInserter: any TextInserting,
    focusProvider: any FocusProviding,
    recovery: TranscriptRecovery = TranscriptRecovery(),
    history: TranscriptHistoryStore = TranscriptHistoryStore(),
    diagnostics: DiagnosticStore = .shared,
    audioPolicy: AudioPolicy = .default,
    textPipeline: TextPipeline = TextPipeline(),
    settings: VaniSettings = .default
  ) {
    self.audioCapture = audioCapture
    self.speechRecognizer = speechRecognizer
    self.textInserter = textInserter
    self.focusProvider = focusProvider
    self.recovery = recovery
    self.history = history
    self.diagnostics = diagnostics
    self.audioPolicy = audioPolicy
    self.textPipeline = textPipeline
    self.settings = settings
  }

  public func setObserver(_ observer: Observer?) async {
    self.observer = observer
    await publishSnapshot()
  }

  public func snapshot() async -> SessionSnapshot {
    await makeSnapshot()
  }

  public func modelsAreInstalled() async -> Bool {
    await speechRecognizer.modelsAreInstalled()
  }

  public func updateSettings(_ settings: VaniSettings) {
    self.settings = settings
  }

  @discardableResult
  public func prepareModels(allowDownload: Bool) async -> Bool {
    guard
      machine.phase == .setup || machine.phase == .ready
        || machine.phase == .recoverableError
    else {
      await recordIgnored("prepare", phase: machine.phase)
      return false
    }
    guard !isPreparingRequest else {
      await recordIgnored("preparation_request_in_progress", phase: machine.phase)
      return false
    }
    isPreparingRequest = true
    defer { isPreparingRequest = false }

    let installed = await speechRecognizer.modelsAreInstalled()
    guard installed || allowDownload else {
      failure = .modelUnavailable
      await publishSnapshot()
      return false
    }

    do {
      let event: SessionEvent =
        machine.phase == .recoverableError
        ? .retryPreparation
        : .prepare
      try await transition(event)
      return await runPreparation()
    } catch {
      await fail(.internalInvariant)
      return false
    }
  }

  public func beginDictation() async {
    guard machine.phase == .ready, !isStartingCapture else {
      await recordIgnored("capture_start", phase: machine.phase)
      return
    }
    isStartingCapture = true
    defer { isStartingCapture = false }

    currentTarget = await focusProvider.currentTarget()
    guard machine.phase == .ready else {
      await recordIgnored("capture_start_cancelled", phase: machine.phase)
      return
    }
    await recovery.clear()
    failure = nil

    do {
      try await audioCapture.start()
      guard machine.phase == .ready else {
        await audioCapture.cancel()
        await recordIgnored("capture_start_cancelled", phase: machine.phase)
        return
      }
      try await transition(.captureStarted)
    } catch {
      await fail(map(error, fallback: .audioCaptureFailed))
    }
  }

  public func endDictation() async {
    guard machine.phase == .listening else {
      await recordIgnored("capture_stop", phase: machine.phase)
      return
    }

    do {
      try await transition(.captureStopped)
      let audio = try await audioCapture.stop()
      try audioPolicy.validate(audio)
      await recovery.retainAudio(audio, target: currentTarget)
      try await transcribeAndInsert(audio)
    } catch {
      await fail(map(error, fallback: .audioCaptureFailed))
    }
  }

  public func retry() async {
    guard machine.phase == .recoverableError, let failure else {
      await recordIgnored("retry", phase: machine.phase)
      return
    }

    switch failure.recoveryAction {
    case .retryPreparation:
      do {
        try await transition(.retryPreparation)
        _ = await runPreparation()
      } catch {
        await fail(.internalInvariant)
      }

    case .retryTranscription:
      guard let audio = await recovery.latest()?.audio else {
        await fail(.internalInvariant)
        return
      }
      do {
        try await transition(.retryTranscription)
        try await transcribeAndInsert(audio)
      } catch {
        await fail(map(error, fallback: .transcriptionFailed))
      }

    case .retryInsertion:
      guard let payload = await recovery.latest(), payload.transcript != nil else {
        await fail(.internalInvariant)
        return
      }
      do {
        try await transition(.retryInsertion)
        try await insertRecoveredTranscript(payload)
      } catch {
        await fail(map(error, fallback: .insertionFailed))
      }

    case .openMicrophoneSettings, .openAccessibilitySettings, .copyTranscript,
      .startAgain, .none:
      await recordIgnored("retry_unsupported", phase: machine.phase)
    }
  }

  public func copyRecoveredTranscript() async throws {
    guard let transcript = await recovery.latest()?.transcript else {
      throw VaniFailure.emptyTranscript
    }
    try await textInserter.copyForManualPaste(transcript)
    await diagnostics.record(
      DiagnosticEvent(category: .recovery, code: "transcript_copied", phase: machine.phase)
    )
  }

  public func discardRecovery() async {
    await recovery.clear()
    failure = nil
    guard machine.phase == .recoverableError else {
      await publishSnapshot()
      return
    }

    do {
      try await transition(modelReady ? .dismissToReady : .dismissToSetup)
    } catch {
      await fail(.internalInvariant)
    }
  }

  public func permissionWasRevoked(_ permissionFailure: VaniFailure) async {
    switch machine.phase {
    case .setup, .preparing, .ready, .listening:
      await audioCapture.cancel()
      failure = permissionFailure
      do {
        try await transition(.permissionsLost)
      } catch {
        await fail(.internalInvariant)
      }

    case .transcribing, .inserting, .recoverableError:
      await diagnostics.record(
        DiagnosticEvent(
          category: .permission,
          code: permissionFailure.code,
          phase: machine.phase
        )
      )
      await publishSnapshot()

    case .disabled:
      await recordIgnored("permission_revoked", phase: machine.phase)
    }
  }

  public func permissionsWereRestored() async {
    guard machine.phase == .recoverableError,
      failure == .microphonePermissionDenied || failure == .accessibilityPermissionDenied
    else {
      return
    }

    failure = nil
    do {
      try await transition(modelReady ? .dismissToReady : .dismissToSetup)
    } catch {
      await fail(.internalInvariant)
    }
  }

  public func audioRouteDidChange() async {
    await audioCapture.cancel()
    if machine.phase == .listening {
      failure = .audioDeviceUnavailable
    }
    do {
      try await transition(.audioRouteChanged)
    } catch {
      await recordIgnored("audio_route_change", phase: machine.phase)
    }
  }

  public func systemWillSleep() async {
    await audioCapture.cancel()
    if machine.phase == .listening {
      failure = .operationCancelled
    }
    do {
      try await transition(.systemWillSleep)
    } catch {
      await recordIgnored("system_sleep", phase: machine.phase)
    }
  }

  public func resumeAfterSystemChange() async {
    guard machine.phase == .preparing else {
      await recordIgnored("system_resume", phase: machine.phase)
      return
    }

    if modelReady {
      do {
        try await transition(.preparationSucceeded)
      } catch {
        await fail(.internalInvariant)
      }
    } else {
      _ = await runPreparation()
    }
  }

  public func terminate() async {
    await audioCapture.cancel()
    do {
      try await transition(.terminate)
    } catch {
      await recordIgnored("terminate", phase: machine.phase)
    }
  }

  private func runPreparation() async -> Bool {
    guard !isPreparingModel else {
      await recordIgnored("preparation_in_progress", phase: machine.phase)
      return false
    }
    isPreparingModel = true
    defer { isPreparingModel = false }

    modelProgress = 0
    failure = nil
    let signpost = VaniSignpost.beginModelPreparation()
    defer { VaniSignpost.endModelPreparation(signpost) }
    preparationGeneration &+= 1
    let generation = preparationGeneration
    await publishSnapshot()

    do {
      try await speechRecognizer.prepare { [weak self] progress in
        Task {
          await self?.updateModelProgress(progress, generation: generation)
        }
      }
      modelProgress = nil
      modelReady = true
      guard machine.phase == .preparing else {
        await publishSnapshot()
        return false
      }
      try await transition(.preparationSucceeded)
      return true
    } catch {
      modelProgress = nil
      guard machine.phase == .preparing else {
        await publishSnapshot()
        return false
      }
      modelReady = false
      await fail(map(error, fallback: .modelLoadFailed))
      return false
    }
  }

  private func updateModelProgress(_ progress: Double, generation: UInt64) async {
    guard generation == preparationGeneration, machine.phase == .preparing else {
      return
    }
    modelProgress = min(max(progress, 0), 1)
    await publishSnapshot()
  }

  private func transcribeAndInsert(_ audio: CapturedAudio) async throws {
    let startedAt = Date()
    let result: SpeechResult
    do {
      let signpost = VaniSignpost.beginTranscription()
      defer { VaniSignpost.endTranscription(signpost) }
      result = try await speechRecognizer.transcribe(audio)
    }
    let text = textPipeline.process(result.text, dictionary: settings.dictionary)
    guard !text.isEmpty else { throw VaniFailure.emptyTranscript }

    await diagnostics.record(
      DiagnosticEvent(
        category: .transcription,
        code: "completed",
        phase: machine.phase,
        durationMilliseconds: milliseconds(since: startedAt)
      )
    )
    await recovery.retainTranscript(text, target: currentTarget)
    try await transition(.transcriptReady)
    guard let payload = await recovery.latest() else {
      throw VaniFailure.internalInvariant
    }
    try await insertRecoveredTranscript(payload)
  }

  private func insertRecoveredTranscript(_ payload: RecoveryPayload) async throws {
    guard let transcript = payload.transcript else {
      throw VaniFailure.emptyTranscript
    }

    let startedAt = Date()
    let signpost = VaniSignpost.beginInsertion()
    defer { VaniSignpost.endInsertion(signpost) }
    let result = try await textInserter.insert(transcript, into: payload.target)
    switch result {
    case .verified, .verifiedClipboardPreserved:
      let diagnosticCode =
        result == .verified
        ? "verified"
        : "verified_clipboard_preserved"
      await diagnostics.record(
        DiagnosticEvent(
          category: .insertion,
          code: diagnosticCode,
          phase: machine.phase,
          durationMilliseconds: milliseconds(since: startedAt)
        )
      )
      if settings.historyEnabled {
        do {
          try await history.append(
            TranscriptHistoryEntry(text: transcript),
            limit: settings.historyLimit
          )
        } catch {
          await diagnostics.record(
            DiagnosticEvent(category: .storage, code: "history_write_failed")
          )
        }
      }
      await recovery.clear()
      currentTarget = nil
      failure = nil
      try await transition(.insertionSucceeded)

    case .manualPasteRequired:
      throw VaniFailure.insertionUnverified
    }
  }

  private func fail(_ failure: VaniFailure) async {
    self.failure = failure
    VaniLog.failure(failure, phase: machine.phase)
    await diagnostics.record(
      DiagnosticEvent(
        category: diagnosticCategory(for: failure),
        code: failure.code,
        phase: machine.phase
      )
    )

    do {
      try machine.transition(.failed)
    } catch {
      if machine.phase != .recoverableError {
        self.failure = .internalInvariant
      }
    }
    await publishSnapshot()
  }

  private func transition(_ event: SessionEvent) async throws {
    try machine.transition(event)
    VaniLog.phase(machine.phase)
    await diagnostics.record(
      DiagnosticEvent(
        category: .lifecycle,
        code: "transition_\(event.rawValue)",
        phase: machine.phase
      )
    )
    await publishSnapshot()
  }

  private func recordIgnored(_ event: String, phase: SessionPhase) async {
    await diagnostics.record(
      DiagnosticEvent(
        category: .lifecycle,
        code: "ignored_\(event)",
        phase: phase
      )
    )
  }

  private func publishSnapshot() async {
    observer?(await makeSnapshot())
  }

  private func makeSnapshot() async -> SessionSnapshot {
    let payload = await recovery.latest()
    return SessionSnapshot(
      phase: machine.phase,
      failure: failure,
      modelProgress: modelProgress,
      isModelReady: modelReady,
      hasRecoverableTranscript: payload?.transcript != nil,
      recoverableTranscript: payload?.transcript
    )
  }

  private func map(_ error: Error, fallback: VaniFailure) -> VaniFailure {
    error as? VaniFailure ?? fallback
  }

  private func milliseconds(since date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) * 1_000))
  }

  private func diagnosticCategory(for failure: VaniFailure) -> DiagnosticCategory {
    switch failure {
    case .microphonePermissionDenied, .accessibilityPermissionDenied: .permission
    case .audioDeviceUnavailable, .audioCaptureFailed, .recordingTooShort,
      .recordingTooLong, .noSpeechDetected:
      .capture
    case .modelUnavailable, .modelDownloadFailed, .modelIntegrityFailed, .modelLoadFailed: .model
    case .transcriptionFailed, .emptyTranscript: .transcription
    case .focusChanged, .insertionFailed, .insertionUnverified, .clipboardChanged:
      .insertion
    case .historyCorrupt: .storage
    case .unsupportedHardware, .operationCancelled, .internalInvariant: .lifecycle
    }
  }
}

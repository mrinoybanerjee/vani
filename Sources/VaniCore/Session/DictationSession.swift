import Foundation

public actor DictationSession {
  public typealias Observer = @MainActor @Sendable (SessionSnapshot) -> Void

  private let audioCapture: any AudioCapturing
  private let speechRecognizer: any SpeechRecognizing
  private let textInserter: any TextInserting
  private let focusProvider: any FocusProviding
  private let recovery: TranscriptRecovery
  private let history: TranscriptHistoryStore
  private let diagnostics: DiagnosticStore
  private let audioPolicy: AudioPolicy
  private let textPipeline: TextPipeline
  private let transientFailureDuration: Duration

  private var machine = SessionStateMachine()
  private var settings: VaniSettings
  private var learnedCorrections: [LearnedCorrection]
  private var failure: VaniFailure?
  private var modelProgress: Double?
  private var modelReady = false
  private var isPreparingModel = false
  private var isPreparingRequest = false
  private var preparationGeneration: UInt64 = 0
  private var isStartingCapture = false
  private var shouldStopAfterCaptureStarts = false
  private var shouldCancelAfterCaptureStarts = false
  private var isPastingLastTranscript = false
  private var currentTarget: TextTarget?
  private var lastTranscript: String?
  private var lastCorrectionCandidate: CorrectionCandidate?
  private var insertionFeedback: InsertionFeedback?
  private var observer: Observer?
  private var snapshotGeneration: UInt64 = 0
  private var recordingLimitTask: Task<Void, Never>?
  private var recordingLimitGeneration: UInt64 = 0
  private var isRecordingLimitApproaching = false
  private var didUnexpectedlyTruncateCurrentAudio = false
  private var historyRevision: UInt64 = 0

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
    settings: VaniSettings = .default,
    learnedCorrections: [LearnedCorrection] = [],
    transientFailureDuration: Duration = .milliseconds(1_000)
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
    self.learnedCorrections = PersonalizationEngine.normalizedProfile(learnedCorrections)
    self.transientFailureDuration = transientFailureDuration
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

  public func personalizationModelsAreInstalled() async -> Bool {
    await speechRecognizer.personalizationModelsAreInstalled()
  }

  public func preparePersonalizationModels(
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try await speechRecognizer.preparePersonalizationModels(progress: progress)
  }

  public func updateSettings(_ settings: VaniSettings) {
    self.settings = settings
  }

  public func updatePersonalization(_ corrections: [LearnedCorrection]) {
    learnedCorrections = PersonalizationEngine.normalizedProfile(corrections)
  }

  public func correctionCandidate() -> CorrectionCandidate? {
    lastCorrectionCandidate
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
    // Paste Last shares the ready phase across suspensions; starting now would clear
    // the transcript it is about to insert.
    guard machine.phase == .ready, !isStartingCapture, !isPastingLastTranscript else {
      await recordIgnored("capture_start", phase: machine.phase)
      return
    }
    isStartingCapture = true
    shouldStopAfterCaptureStarts = false
    shouldCancelAfterCaptureStarts = false
    defer {
      isStartingCapture = false
      shouldCancelAfterCaptureStarts = false
      if machine.phase != .listening {
        shouldStopAfterCaptureStarts = false
      }
    }

    currentTarget = await focusProvider.currentTarget()
    guard machine.phase == .ready else {
      await recordIgnored("capture_start_cancelled", phase: machine.phase)
      return
    }
    guard currentTarget?.isSecureTextField != true else {
      await fail(.secureTextField)
      return
    }
    await recovery.clear()
    failure = nil
    insertionFeedback = nil
    didUnexpectedlyTruncateCurrentAudio = false

    do {
      let captureStartedAt = ContinuousClock().now
      try await audioCapture.start()
      guard machine.phase == .ready, !shouldCancelAfterCaptureStarts else {
        await audioCapture.cancel()
        currentTarget = nil
        await recordIgnored("capture_start_cancelled", phase: machine.phase)
        return
      }
      try await transition(.captureStarted)
      guard machine.phase == .listening else { return }
      if settings.personalizationEnabled, !learnedCorrections.isEmpty {
        let recognizer = speechRecognizer
        Task(priority: .userInitiated) { await recognizer.prewarmPersonalization() }
      }
      if shouldStopAfterCaptureStarts {
        shouldStopAfterCaptureStarts = false
        await finishDictation()
      } else {
        startRecordingLimitTimer(startedAt: captureStartedAt)
      }
    } catch {
      guard machine.phase != .disabled else { return }
      await fail(map(error, fallback: .audioCaptureFailed))
    }
  }

  public func endDictation() async {
    if isStartingCapture {
      shouldStopAfterCaptureStarts = true
      VaniLog.event(category: .capture, code: "capture_stop_queued")
      return
    }
    guard machine.phase == .listening else {
      await recordIgnored("capture_stop", phase: machine.phase)
      return
    }

    await finishDictation()
  }

  /// Discards the active recording without transcription or insertion.
  public func cancelDictation() async {
    if isStartingCapture {
      shouldCancelAfterCaptureStarts = true
      VaniLog.event(category: .capture, code: "capture_cancel_queued")
      return
    }
    guard machine.phase == .listening else {
      await recordIgnored("capture_cancel", phase: machine.phase)
      return
    }
    cancelRecordingLimitTimer()
    do {
      // Reserve the transition first so a concurrent release cannot finalize this audio.
      try machine.transition(.captureCancelled)
    } catch {
      await recordIgnored("capture_cancel", phase: machine.phase)
      return
    }
    await audioCapture.cancel()
    await recovery.clear()
    currentTarget = nil
    failure = nil
    didUnexpectedlyTruncateCurrentAudio = false
    VaniLog.event(category: .capture, code: "capture_cancelled")
    await publishTransition(.captureCancelled)
  }

  private func finishDictation(automaticallyStopped: Bool = false) async {
    cancelRecordingLimitTimer()
    do {
      // Reserve finalization before suspending, but publish the stopped cue only
      // after the microphone has stopped so the cue is not recorded.
      try machine.transition(.captureStopped)
      let audio = try await audioCapture.stop()
      guard machine.phase == .transcribing else { return }
      await publishTransition(.captureStopped)
      if automaticallyStopped {
        await diagnostics.record(
          DiagnosticEvent(
            category: .capture,
            code: "capture_limit_auto_stop",
            phase: machine.phase
          )
        )
      }
      guard machine.phase == .transcribing else { return }
      guard try await retainAndValidate(audio) else { return }
      try await transcribeAndInsert(audio)
    } catch {
      guard machine.phase != .disabled else { return }
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
        await recordCaptureTruncationIfNeeded(audio)
        try await transcribeAndInsert(audio)
      } catch {
        guard machine.phase != .disabled else { return }
        await fail(map(error, fallback: .transcriptionFailed))
      }

    case .retryAudioFinalization:
      do {
        try await transition(.retryTranscription)
        guard let audio = try await audioCapture.recoverPendingAudio() else {
          throw VaniFailure.internalInvariant
        }
        guard machine.phase == .transcribing else { return }
        guard try await retainAndValidate(audio) else { return }
        try await transcribeAndInsert(audio)
      } catch {
        guard machine.phase != .disabled else { return }
        await fail(map(error, fallback: .audioFinalizationFailed))
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
        guard machine.phase != .disabled else { return }
        await fail(map(error, fallback: .insertionFailed))
      }

    case .openMicrophoneSettings, .openAccessibilitySettings, .openInputMonitoringSettings,
      .copyTranscript, .startAgain, .none:
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

  public func transcriptForNote() -> String? { lastTranscript }

  public func copyLastTranscript() async throws {
    guard let lastTranscript else {
      throw VaniFailure.emptyTranscript
    }
    try await textInserter.copyForManualPaste(lastTranscript)
    await diagnostics.record(
      DiagnosticEvent(category: .recovery, code: "last_transcript_copied", phase: machine.phase)
    )
  }

  public func pasteLastTranscript() async {
    guard machine.phase == .ready, !isPastingLastTranscript, !isStartingCapture else {
      await recordIgnored("paste_last", phase: machine.phase)
      return
    }
    guard let lastTranscript else {
      await recordIgnored("paste_last_empty", phase: machine.phase)
      return
    }

    isPastingLastTranscript = true
    defer { isPastingLastTranscript = false }

    currentTarget = await focusProvider.currentTarget()
    guard machine.phase == .ready else {
      await recordIgnored("paste_last_cancelled", phase: machine.phase)
      return
    }

    failure = nil
    insertionFeedback = nil
    await recovery.retainTranscript(
      lastTranscript,
      target: currentTarget,
      shouldAppendToHistory: false
    )

    do {
      try await transition(.pasteLastRequested)
      guard let payload = await recovery.latest() else {
        throw VaniFailure.internalInvariant
      }
      try await insertRecoveredTranscript(payload)
    } catch {
      guard machine.phase != .disabled else { return }
      await fail(map(error, fallback: .insertionFailed))
    }
  }

  public func discardRecovery() async {
    let shouldDiscardPendingAudio = failure == .audioFinalizationFailed
    await recovery.clear()
    if shouldDiscardPendingAudio {
      await audioCapture.cancel()
    }
    failure = nil
    didUnexpectedlyTruncateCurrentAudio = false
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
    case .listening:
      await preserveInterruptedDictation(
        diagnosticCode: "capture_interrupted_\(permissionFailure.code)"
      )

    case .setup, .preparing, .ready:
      cancelRecordingLimitTimer()
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
        || failure == .inputMonitoringPermissionDenied
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
    cancelRecordingLimitTimer()
    if machine.phase == .listening {
      await preserveInterruptedDictation(diagnosticCode: "capture_interrupted_audio_route")
      return
    }
    if isStartingCapture {
      await audioCapture.cancel()
    }
    do {
      try await transition(.audioRouteChanged)
    } catch {
      await recordIgnored("audio_route_change", phase: machine.phase)
    }
  }

  public func systemWillSleep() async {
    cancelRecordingLimitTimer()
    if machine.phase == .listening {
      await preserveInterruptedDictation(diagnosticCode: "capture_interrupted_sleep")
      return
    }
    if isStartingCapture {
      await audioCapture.cancel()
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
    preparationGeneration &+= 1
    cancelRecordingLimitTimer()
    await audioCapture.cancel()
    await recovery.clear()
    currentTarget = nil
    failure = nil
    modelProgress = nil
    didUnexpectedlyTruncateCurrentAudio = false
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
    let settingsSnapshot = settings
    let correctionsSnapshot = learnedCorrections
    let targetBundleIdentifier = currentTarget?.bundleIdentifier
    let result: SpeechResult
    do {
      let signpost = VaniSignpost.beginTranscription()
      defer { VaniSignpost.endTranscription(signpost) }
      let personalizedTerms =
        settingsSnapshot.personalizationEnabled
        ? PersonalizationEngine().activeAcousticTerms(
          corrections: correctionsSnapshot,
          applicationBundleIdentifier: targetBundleIdentifier,
          manualDictionary: settingsSnapshot.dictionary,
          snippets: settingsSnapshot.snippets
        )
        : []
      result = try await speechRecognizer.transcribe(
        audio,
        context: SpeechRecognitionContext(personalizedTerms: personalizedTerms)
      )
    }
    guard machine.phase == .transcribing else { return }
    let text = textPipeline.process(
      result.text,
      dictionary: settingsSnapshot.dictionary,
      snippets: settingsSnapshot.snippets,
      smartFormattingEnabled: settingsSnapshot.smartFormattingEnabled,
      learnedCorrections: settingsSnapshot.personalizationEnabled ? correctionsSnapshot : [],
      applicationBundleIdentifier: targetBundleIdentifier
    )
    guard !text.isEmpty else { throw VaniFailure.emptyTranscript }
    lastTranscript = text
    lastCorrectionCandidate = CorrectionCandidate(
      rawTranscript: result.rawText ?? result.text,
      recognizedTranscript: result.text,
      finalTranscript: text,
      applicationBundleIdentifier: targetBundleIdentifier
    )

    await diagnostics.record(
      DiagnosticEvent(
        category: .transcription,
        code: "completed",
        phase: machine.phase,
        durationMilliseconds: milliseconds(since: startedAt)
      )
    )
    guard machine.phase == .transcribing else { return }
    await recovery.retainTranscript(text, target: currentTarget)
    guard machine.phase == .transcribing else { return }
    try await transition(.transcriptReady)
    guard let payload = await recovery.latest() else {
      throw VaniFailure.internalInvariant
    }
    try await insertRecoveredTranscript(payload)
  }

  private func insertRecoveredTranscript(_ payload: RecoveryPayload) async throws {
    guard machine.phase == .inserting else { return }
    guard let transcript = payload.transcript else {
      throw VaniFailure.emptyTranscript
    }

    let startedAt = Date()
    let signpost = VaniSignpost.beginInsertion()
    defer { VaniSignpost.endInsertion(signpost) }
    let result = try await textInserter.insert(transcript, into: payload.target)
    guard machine.phase == .inserting else { return }

    let diagnosticCode: String
    switch result {
    case .verified:
      diagnosticCode = "verified"
      insertionFeedback =
        didUnexpectedlyTruncateCurrentAudio
        ? .verifiedCaptureTruncated
        : .verified
    case .verifiedClipboardPreserved:
      diagnosticCode = "verified_clipboard_preserved"
      insertionFeedback =
        didUnexpectedlyTruncateCurrentAudio
        ? .verifiedCaptureTruncated
        : .verified
    case .unverifiedClipboardPreserved:
      diagnosticCode = "unverified_clipboard_preserved"
      insertionFeedback = .unconfirmed
    case .manualPasteRequired:
      throw VaniFailure.insertionUnverified
    }

    VaniLog.event(category: .insertion, code: diagnosticCode)
    await diagnostics.record(
      DiagnosticEvent(
        category: .insertion,
        code: diagnosticCode,
        phase: machine.phase,
        durationMilliseconds: milliseconds(since: startedAt)
      )
    )
    guard machine.phase == .inserting else { return }
    let historyLimit =
      settings.historyEnabled && payload.shouldAppendToHistory
      ? settings.historyLimit : nil
    await recovery.clear()
    currentTarget = nil
    failure = nil
    try await transition(.insertionSucceeded)
    // The text is already delivered; rewriting history must not delay the next dictation.
    if let historyLimit {
      do {
        try await history.append(TranscriptHistoryEntry(text: transcript), limit: historyLimit)
        historyRevision &+= 1
        await publishSnapshot()
      } catch {
        await diagnostics.record(
          DiagnosticEvent(category: .storage, code: "history_write_failed")
        )
      }
    }
  }

  private func fail(_ failure: VaniFailure) async {
    let failedPhase = machine.phase
    self.failure = failure
    do {
      try machine.transition(.failed)
    } catch {
      if machine.phase != .recoverableError {
        self.failure = .internalInvariant
      }
    }
    VaniLog.failure(failure, phase: failedPhase)
    await diagnostics.record(
      DiagnosticEvent(
        category: diagnosticCategory(for: failure),
        code: failure.code,
        phase: failedPhase
      )
    )
    await publishSnapshot()

    guard failure.dismissesAutomatically else { return }
    try? await Task.sleep(for: transientFailureDuration)
    guard machine.phase == .recoverableError, self.failure == failure else { return }

    await recovery.clear()
    currentTarget = nil
    self.failure = nil
    do {
      try await transition(modelReady ? .dismissToReady : .dismissToSetup)
    } catch {
      self.failure = .internalInvariant
      await publishSnapshot()
    }
  }

  private func transition(_ event: SessionEvent) async throws {
    try machine.transition(event)
    await publishTransition(event)
  }

  private func publishTransition(_ event: SessionEvent) async {
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
    snapshotGeneration &+= 1
    let generation = snapshotGeneration
    let snapshot = await makeSnapshot()
    guard generation == snapshotGeneration else { return }
    await observer?(snapshot)
  }

  private func makeSnapshot() async -> SessionSnapshot {
    let payload = await recovery.latest()
    return SessionSnapshot(
      phase: machine.phase,
      failure: failure,
      modelProgress: modelProgress,
      isModelReady: modelReady,
      hasLastTranscript: lastTranscript != nil,
      hasRecoverableTranscript: payload?.transcript != nil,
      recoverableTranscript: payload?.transcript,
      insertionFeedback: insertionFeedback,
      isRecordingLimitApproaching: isRecordingLimitApproaching,
      historyRevision: historyRevision
    )
  }

  private func startRecordingLimitTimer(startedAt: ContinuousClock.Instant) {
    cancelRecordingLimitTimer()
    recordingLimitGeneration &+= 1
    let generation = recordingLimitGeneration
    let maximumDuration = max(0, audioPolicy.maximumDuration)
    let warningLeadTime = min(60, maximumDuration / 2)
    let warningDelay = max(0, maximumDuration - warningLeadTime)
    let warningDeadline = startedAt.advanced(by: .seconds(warningDelay))
    let stopDeadline = startedAt.advanced(by: .seconds(maximumDuration))
    let clock = ContinuousClock()

    recordingLimitTask = Task { [weak self] in
      do {
        if warningDelay > 0 {
          try await clock.sleep(until: warningDeadline)
        }
        guard !Task.isCancelled else { return }
        await self?.recordingLimitWarningReached(generation: generation)

        if warningLeadTime > 0 {
          try await clock.sleep(until: stopDeadline)
        }
        guard !Task.isCancelled else { return }
        await self?.recordingLimitReached(generation: generation)
      } catch {
        return
      }
    }
  }

  private func recordingLimitWarningReached(generation: UInt64) async {
    guard
      generation == recordingLimitGeneration,
      machine.phase == .listening
    else {
      return
    }
    isRecordingLimitApproaching = true
    VaniLog.event(category: .capture, code: "capture_limit_warning")
    await diagnostics.record(
      DiagnosticEvent(
        category: .capture,
        code: "capture_limit_warning",
        phase: machine.phase
      )
    )
    await publishSnapshot()
  }

  private func recordingLimitReached(generation: UInt64) async {
    guard
      generation == recordingLimitGeneration,
      machine.phase == .listening
    else {
      return
    }
    recordingLimitTask = nil
    isRecordingLimitApproaching = false
    VaniLog.event(category: .capture, code: "capture_limit_auto_stop")
    await finishDictation(automaticallyStopped: true)
  }

  private func cancelRecordingLimitTimer() {
    recordingLimitGeneration &+= 1
    recordingLimitTask?.cancel()
    recordingLimitTask = nil
    isRecordingLimitApproaching = false
  }

  private func captureWasUnexpectedlyTruncated(_ audio: CapturedAudio) -> Bool {
    guard audio.wasTruncated else { return false }
    let tolerance = min(
      1,
      max(0.05, audioPolicy.maximumDuration * 0.001)
    )
    return audio.duration < audioPolicy.maximumDuration - tolerance
  }

  private func retainAndValidate(_ audio: CapturedAudio) async throws -> Bool {
    await recovery.retainAudio(audio, target: currentTarget)
    guard machine.phase == .transcribing else { return false }
    await recordCaptureTruncationIfNeeded(audio)
    try audioPolicy.validate(audio)
    return machine.phase == .transcribing
  }

  private func preserveInterruptedDictation(diagnosticCode: String) async {
    cancelRecordingLimitTimer()
    do {
      // Interruption cues obey the same microphone-stop boundary as manual release.
      try machine.transition(.captureStopped)
      let audio = try await audioCapture.stop()
      guard machine.phase == .transcribing else { return }
      await publishTransition(.captureStopped)
      guard machine.phase == .transcribing else { return }
      await recovery.retainAudio(audio, target: currentTarget)
      guard machine.phase == .transcribing else { return }
      await recordCaptureTruncationIfNeeded(audio)
      await diagnostics.record(
        DiagnosticEvent(
          category: .capture,
          code: diagnosticCode,
          phase: machine.phase
        )
      )
      await fail(.recordingInterrupted)
    } catch {
      guard machine.phase != .disabled else { return }
      await fail(map(error, fallback: .audioCaptureFailed))
    }
  }

  private func recordCaptureTruncationIfNeeded(_ audio: CapturedAudio) async {
    didUnexpectedlyTruncateCurrentAudio = captureWasUnexpectedlyTruncated(audio)
    if audio.wasTruncated {
      let code =
        didUnexpectedlyTruncateCurrentAudio
        ? "capture_truncated_early"
        : "capture_limit_reached"
      VaniLog.event(category: .capture, code: code)
      await diagnostics.record(
        DiagnosticEvent(
          category: .capture,
          code: code,
          phase: machine.phase
        )
      )
    }
  }

  private func map(_ error: Error, fallback: VaniFailure) -> VaniFailure {
    error as? VaniFailure ?? fallback
  }

  private func milliseconds(since date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) * 1_000))
  }

  private func diagnosticCategory(for failure: VaniFailure) -> DiagnosticCategory {
    switch failure {
    case .microphonePermissionDenied, .accessibilityPermissionDenied,
      .inputMonitoringPermissionDenied:
      .permission
    case .audioDeviceUnavailable, .unsupportedInputSampleRate, .audioCaptureFailed,
      .audioFinalizationFailed, .recordingInterrupted, .recordingTooShort,
      .recordingTooLong, .noSpeechDetected:
      .capture
    case .modelUnavailable, .modelDownloadFailed, .modelIntegrityFailed, .modelLoadFailed: .model
    case .transcriptionFailed, .emptyTranscript: .transcription
    case .focusChanged, .secureTextField, .insertionFailed, .insertionUnverified,
      .clipboardChanged:
      .insertion
    case .historyCorrupt: .storage
    case .unsupportedHardware, .internalInvariant: .lifecycle
    }
  }
}

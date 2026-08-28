import Foundation
import Testing

@testable import VaniCore

private actor MockAudioCapture: AudioCapturing {
  let audio: CapturedAudio
  let startDelay: Duration?
  let startFailure: VaniFailure?
  let stopFailure: VaniFailure?
  private var pendingAudio: CapturedAudio?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var recoverPendingCount = 0
  private(set) var cancelCount = 0

  init(
    audio: CapturedAudio = CapturedAudio(samples: Array(repeating: 0.05, count: 8_000)),
    startDelay: Duration? = nil,
    startFailure: VaniFailure? = nil,
    stopFailure: VaniFailure? = nil,
    pendingAudio: CapturedAudio? = nil
  ) {
    self.audio = audio
    self.startDelay = startDelay
    self.startFailure = startFailure
    self.stopFailure = stopFailure
    self.pendingAudio = pendingAudio
  }

  func start() async throws {
    startCount += 1
    if let startDelay {
      try await Task.sleep(for: startDelay)
    }
    if let startFailure {
      throw startFailure
    }
  }

  func stop() async throws -> CapturedAudio {
    stopCount += 1
    if let stopFailure {
      throw stopFailure
    }
    return audio
  }

  func recoverPendingAudio() async throws -> CapturedAudio? {
    recoverPendingCount += 1
    let audio = pendingAudio
    pendingAudio = nil
    return audio
  }

  func waitUntilStart() async -> Bool {
    for _ in 0..<5_000 {
      if startCount > 0 { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func cancel() async {
    cancelCount += 1
    pendingAudio = nil
  }
}

private actor MockSpeechRecognizer: SpeechRecognizing {
  private var results: [Result<SpeechResult, VaniFailure>]
  private let modelsInstalled: Bool
  private let modelCheckDelay: Duration?
  private let prepareDelay: Duration?
  private let prepareFailure: VaniFailure?
  private let pausesPreparation: Bool
  private var preparationContinuation: CheckedContinuation<Void, Never>?
  private var preparationReleased = false
  private let transcribeDelay: Duration?
  private let pausesTranscription: Bool
  private var transcriptionContinuation: CheckedContinuation<Void, Never>?
  private var transcriptionReleased = false
  private(set) var prepareCount = 0
  private(set) var transcribeCount = 0
  private(set) var contexts: [SpeechRecognitionContext] = []

  init(
    results: [Result<SpeechResult, VaniFailure>],
    modelsInstalled: Bool = true,
    modelCheckDelay: Duration? = nil,
    prepareDelay: Duration? = nil,
    prepareFailure: VaniFailure? = nil,
    pausesPreparation: Bool = false,
    transcribeDelay: Duration? = nil,
    pausesTranscription: Bool = false
  ) {
    self.results = results
    self.modelsInstalled = modelsInstalled
    self.modelCheckDelay = modelCheckDelay
    self.prepareDelay = prepareDelay
    self.prepareFailure = prepareFailure
    self.pausesPreparation = pausesPreparation
    self.transcribeDelay = transcribeDelay
    self.pausesTranscription = pausesTranscription
  }

  func modelsAreInstalled() async -> Bool {
    if let modelCheckDelay {
      try? await Task.sleep(for: modelCheckDelay)
    }
    return modelsInstalled
  }

  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    prepareCount += 1
    if pausesPreparation, !preparationReleased {
      await withCheckedContinuation { continuation in
        preparationContinuation = continuation
      }
    }
    if let prepareDelay {
      try await Task.sleep(for: prepareDelay)
    }
    if let prepareFailure {
      throw prepareFailure
    }
    progress(1)
  }

  func waitUntilPreparationStarts() async -> Bool {
    for _ in 0..<5_000 {
      if prepareCount > 0 { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func resumePreparation() {
    preparationReleased = true
    preparationContinuation?.resume()
    preparationContinuation = nil
  }

  func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult {
    transcribeCount += 1
    if pausesTranscription, !transcriptionReleased {
      await withCheckedContinuation { continuation in
        transcriptionContinuation = continuation
      }
    }
    if let transcribeDelay {
      try await Task.sleep(for: transcribeDelay)
    }
    guard !results.isEmpty else { throw VaniFailure.transcriptionFailed }
    return try results.removeFirst().get()
  }

  func transcribe(
    _ audio: CapturedAudio,
    context: SpeechRecognitionContext
  ) async throws -> SpeechResult {
    contexts.append(context)
    return try await transcribe(audio)
  }

  func waitUntilTranscriptionStarts() async -> Bool {
    await waitUntilTranscriptionCount(1)
  }

  func resumeTranscription() {
    transcriptionReleased = true
    transcriptionContinuation?.resume()
    transcriptionContinuation = nil
  }

  func waitUntilTranscriptionCount(_ count: Int) async -> Bool {
    for _ in 0..<5_000 {
      if transcribeCount >= count { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }
}

@Test @MainActor
func dictationSessionUsesEnabledPersonalizationAndRetainsCorrectionCandidate() async throws {
  let audio = MockAudioCapture()
  let speech = MockSpeechRecognizer(results: [.success(speechResult("Vanny says hello"))])
  let focus = MockFocusProvider()
  focus.target = TextTarget(
    processIdentifier: 42,
    bundleIdentifier: "personalized.app"
  )
  let insertion = MockTextInserter(results: [.success(.verified)])
  let settings = VaniSettings(
    personalizationEnabled: true
  )
  let learnedCorrections = [
    LearnedCorrection(
      spoken: "Vanny",
      replacement: "Vani",
      applicationBundleIdentifier: "personalized.app",
      confirmationCount: 2
    )
  ]
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: focus,
    diagnostics: DiagnosticStore(),
    settings: settings,
    learnedCorrections: learnedCorrections
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  #expect(insertion.insertedTexts == ["Vani says hello"])
  let contexts = await speech.contexts
  #expect(contexts.count == 1)
  #expect(
    contexts[0].personalizedTerms == [
      SpeechPersonalizationTerm(canonical: "Vani", aliases: ["Vanny"])
    ])
  #expect(
    await session.correctionCandidate()?.finalTranscript == "Vani says hello"
  )
  #expect(await session.correctionCandidate()?.rawTranscript == "Vanny says hello")
  #expect(
    await session.correctionCandidate()?.applicationBundleIdentifier == "personalized.app"
  )
}

@MainActor
private final class MockFocusProvider: FocusProviding {
  var target = TextTarget(processIdentifier: 42, bundleIdentifier: "test.target")

  func currentTarget() -> TextTarget? { target }
}

@MainActor
private final class MockTextInserter: TextInserting {
  var results: [Result<TextInsertionResult, VaniFailure>]
  let insertDelay: Duration?
  private(set) var insertedTexts: [String] = []
  private(set) var copiedTexts: [String] = []

  init(
    results: [Result<TextInsertionResult, VaniFailure>],
    insertDelay: Duration? = nil
  ) {
    self.results = results
    self.insertDelay = insertDelay
  }

  func insert(_ text: String, into target: TextTarget?) async throws -> TextInsertionResult {
    insertedTexts.append(text)
    if let insertDelay {
      try await Task.sleep(for: insertDelay)
    }
    guard !results.isEmpty else { throw VaniFailure.insertionFailed }
    return try results.removeFirst().get()
  }

  func copyForManualPaste(_ text: String) throws {
    copiedTexts.append(text)
  }

  func waitUntilInsertionStarts() async -> Bool {
    await waitUntilInsertionCount(1)
  }

  func waitUntilInsertionCount(_ count: Int) async -> Bool {
    for _ in 0..<5_000 {
      if insertedTexts.count >= count { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }
}

private func speechResult(_ text: String) -> SpeechResult {
  SpeechResult(text: text, confidence: 0.95, audioDuration: 0.5, processingDuration: 0.01)
}

@Test @MainActor
func dictationSessionCompletesTheVerifiedHappyPath() async throws {
  let audio = MockAudioCapture()
  let speech = MockSpeechRecognizer(results: [.success(speechResult("hello   world"))])
  let focus = MockFocusProvider()
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: focus,
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(snapshot.hasLastTranscript)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(snapshot.insertionFeedback == .verified)
  #expect(insertion.insertedTexts == ["hello world"])
  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 1)

  try await session.copyLastTranscript()
  #expect(insertion.copiedTexts == ["hello world"])
}

@Test @MainActor
func recordingLimitWarnsThenAutomaticallyFinishesOnce() async throws {
  let audio = MockAudioCapture(
    audio: CapturedAudio(samples: Array(repeating: 0.05, count: 1_600))
  )
  let speech = MockSpeechRecognizer(results: [.success(speechResult("long dictation"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 0.4,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()

  var observedWarning = false
  for _ in 0..<1_000 {
    if await session.snapshot().isRecordingLimitApproaching {
      observedWarning = true
      break
    }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(observedWarning)

  var snapshot = await session.snapshot()
  for _ in 0..<1_000 {
    snapshot = await session.snapshot()
    if snapshot.phase == .ready { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(snapshot.phase == .ready)
  #expect(!snapshot.isRecordingLimitApproaching)
  #expect(await audio.stopCount == 1)
  #expect(await speech.transcribeCount == 1)
  #expect(insertion.insertedTexts == ["long dictation"])

  await session.endDictation()
  #expect(await audio.stopCount == 1)
}

@Test @MainActor
func manualStopCancelsTheRecordingLimitTimer() async throws {
  let audio = MockAudioCapture(
    audio: CapturedAudio(samples: Array(repeating: 0.05, count: 480))
  )
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("short"))]),
    textInserter: MockTextInserter(results: [.success(.verified)]),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 0.05,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  try await Task.sleep(for: .milliseconds(100))

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(!snapshot.isRecordingLimitApproaching)
  #expect(await audio.stopCount == 1)
}

@Test @MainActor
func overLimitAudioIsRetainedAndCanBeTranscribedWithoutRecordingAgain() async throws {
  let audio = MockAudioCapture(
    audio: CapturedAudio(samples: Array(repeating: 0.05, count: 32_000))
  )
  let speech = MockSpeechRecognizer(results: [.success(speechResult("preserved"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 1,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  var snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .recordingTooLong)
  #expect(snapshot.failure?.recoveryAction == .retryTranscription)
  #expect(await speech.transcribeCount == 0)

  await session.retry()

  snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(await audio.startCount == 1)
  #expect(await speech.transcribeCount == 1)
  #expect(insertion.insertedTexts == ["preserved"])
}

@Test @MainActor
func earlyCaptureTruncationIsInsertedWithAnExplicitWarning() async throws {
  let audio = MockAudioCapture(
    audio: CapturedAudio(
      samples: Array(repeating: 0.05, count: 8_000),
      wasTruncated: true
    )
  )
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("partial"))]),
    textInserter: MockTextInserter(results: [.success(.verified)]),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 1,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.insertionFeedback == .verifiedCaptureTruncated)
}

@Test @MainActor
func truncationAtTheExpectedLimitStillReportsNormalInsertion() async throws {
  let audio = MockAudioCapture(
    audio: CapturedAudio(
      samples: Array(repeating: 0.05, count: 16_000),
      wasTruncated: true
    )
  )
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("complete"))]),
    textInserter: MockTextInserter(results: [.success(.verified)]),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 1,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  #expect(await session.snapshot().insertionFeedback == .verified)
}

@Test @MainActor
func automaticStopCanRetryAudioFinalizationWithoutRecordingAgain() async throws {
  let pendingAudio = CapturedAudio(samples: Array(repeating: 0.05, count: 480))
  let audio = MockAudioCapture(
    audio: pendingAudio,
    stopFailure: .audioFinalizationFailed,
    pendingAudio: pendingAudio
  )
  let speech = MockSpeechRecognizer(results: [.success(speechResult("recovered"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    audioPolicy: AudioPolicy(
      minimumDuration: 0.01,
      maximumDuration: 0.05,
      minimumRootMeanSquare: 0.0015
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()

  var failedSnapshot: SessionSnapshot?
  for _ in 0..<1_000 {
    let snapshot = await session.snapshot()
    if snapshot.failure == .audioFinalizationFailed {
      failedSnapshot = snapshot
      break
    }
    try await Task.sleep(for: .milliseconds(1))
  }

  #expect(failedSnapshot?.phase == .recoverableError)
  #expect(failedSnapshot?.failure?.recoveryAction == .retryAudioFinalization)
  #expect(await audio.stopCount == 1)
  #expect(await audio.recoverPendingCount == 0)
  #expect(await speech.transcribeCount == 0)
  #expect(insertion.insertedTexts.isEmpty)

  await session.retry()

  #expect(await session.snapshot().phase == .ready)
  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 1)
  #expect(await audio.recoverPendingCount == 1)
  #expect(await speech.transcribeCount == 1)
  #expect(insertion.insertedTexts == ["recovered"])
}

@Test @MainActor
func routeChangeDoesNotDiscardAudioWaitingForFinalizationRetry() async throws {
  let pendingAudio = CapturedAudio(samples: Array(repeating: 0.05, count: 8_000))
  let audio = MockAudioCapture(
    audio: pendingAudio,
    stopFailure: .audioFinalizationFailed,
    pendingAudio: pendingAudio
  )
  let speech = MockSpeechRecognizer(results: [.success(speechResult("still preserved"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  #expect(await session.snapshot().failure == .audioFinalizationFailed)

  await session.audioRouteDidChange()
  #expect(await audio.cancelCount == 0)
  #expect(await session.snapshot().failure == .audioFinalizationFailed)

  await session.retry()

  #expect(await session.snapshot().phase == .ready)
  #expect(await audio.recoverPendingCount == 1)
  #expect(insertion.insertedTexts == ["still preserved"])
}

@Test @MainActor
func secureTextFieldIsRejectedBeforeAudioCaptureStarts() async {
  let audio = MockAudioCapture()
  let speech = MockSpeechRecognizer(results: [.success(speechResult("secret"))])
  let focus = MockFocusProvider()
  focus.target = TextTarget(
    processIdentifier: 42,
    bundleIdentifier: "test.target",
    isSecureTextField: true
  )
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: focus,
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .secureTextField)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(await audio.startCount == 0)
  #expect(await speech.transcribeCount == 0)
  #expect(insertion.insertedTexts.isEmpty)
}

@Test @MainActor
func unavailableModelStaysInSetupUntilDownloadIsAllowed() async {
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [], modelsInstalled: false),
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await !session.prepareModels(allowDownload: false))

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .setup)
  #expect(snapshot.failure == .modelUnavailable)
  #expect(!snapshot.isModelReady)
}

@Test @MainActor
func modelPreparationFailureIsRecoverable() async {
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(
      results: [],
      prepareFailure: .modelLoadFailed
    ),
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await !session.prepareModels(allowDownload: false))

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .modelLoadFailed)
  #expect(!snapshot.isModelReady)
}

@Test @MainActor
func microphoneStartFailureDoesNotAttemptTranscriptionOrInsertion() async {
  let audio = MockAudioCapture(startFailure: .audioCaptureFailed)
  let speech = MockSpeechRecognizer(results: [.success(speechResult("unused"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .audioCaptureFailed)
  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 0)
  #expect(await speech.transcribeCount == 0)
  #expect(insertion.insertedTexts.isEmpty)
}

@Test @MainActor
func sleepDuringCapturePreservesAudioForRetry() async {
  let audio = MockAudioCapture()
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("unused"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.systemWillSleep()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .recordingInterrupted)
  #expect(snapshot.failure?.recoveryAction == .retryTranscription)
  #expect(snapshot.hasRecoverableTranscript == false)
  #expect(await audio.stopCount == 1)
  #expect(await audio.cancelCount == 0)
  #expect(insertion.insertedTexts.isEmpty)

  await session.retry()
  #expect(await session.snapshot().phase == .ready)
  #expect(insertion.insertedTexts == ["unused"])
}

@Test @MainActor
func audioRouteChangeDuringCapturePreservesAudioForRetry() async {
  let audio = MockAudioCapture()
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("unused"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.audioRouteDidChange()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .recordingInterrupted)
  #expect(snapshot.failure?.recoveryAction == .retryTranscription)
  #expect(await audio.stopCount == 1)
  #expect(await audio.cancelCount == 0)

  await session.retry()
  #expect(await session.snapshot().phase == .ready)
  #expect(insertion.insertedTexts == ["unused"])
}

@Test @MainActor
func terminationCancelsCaptureAndDisablesTheSession() async {
  let audio = MockAudioCapture()
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: []),
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.terminate()

  #expect(await session.snapshot().phase == .disabled)
  #expect(await audio.cancelCount == 1)
}

@Test @MainActor
func terminationDuringTranscriptionCannotInsertOrPublishALateFailure() async {
  let speech = MockSpeechRecognizer(
    results: [.success(speechResult("too late"))],
    pausesTranscription: true
  )
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  let completion = Task { await session.endDictation() }
  #expect(await speech.waitUntilTranscriptionStarts())

  await session.terminate()
  await speech.resumeTranscription()
  await completion.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(insertion.insertedTexts.isEmpty)
}

@Test @MainActor
func terminationDuringInsertionCannotPublishALateFailureOrHistory() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let history = TranscriptHistoryStore(directory: directory)
  let insertion = MockTextInserter(
    results: [.success(.verified)],
    insertDelay: .milliseconds(50)
  )
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("too late"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    history: history,
    diagnostics: DiagnosticStore(),
    settings: VaniSettings(historyEnabled: true)
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  let completion = Task { await session.endDictation() }
  #expect(await insertion.waitUntilInsertionStarts())

  await session.terminate()
  await completion.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(try await history.load().isEmpty)
}

@Test @MainActor
func terminationDuringCaptureStartupCannotPublishALateFailure() async {
  let audio = MockAudioCapture(
    startDelay: .milliseconds(50),
    startFailure: .audioCaptureFailed
  )
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: []),
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  let start = Task { await session.beginDictation() }
  #expect(await audio.waitUntilStart())

  await session.terminate()
  await start.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
}

@Test @MainActor
func terminationDuringTranscriptionRetryCannotPublishALateFailure() async {
  let speech = MockSpeechRecognizer(
    results: [
      .failure(.transcriptionFailed),
      .failure(.transcriptionFailed),
    ],
    transcribeDelay: .milliseconds(50)
  )
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  #expect(await session.snapshot().failure == .transcriptionFailed)

  let retry = Task { await session.retry() }
  #expect(await speech.waitUntilTranscriptionCount(2))
  await session.terminate()
  await retry.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
}

@Test @MainActor
func terminationDuringInsertionRetryCannotPublishALateFailure() async {
  let insertion = MockTextInserter(
    results: [
      .failure(.insertionFailed),
      .failure(.insertionFailed),
    ],
    insertDelay: .milliseconds(50)
  )
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("retry me"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  #expect(await session.snapshot().failure == .insertionFailed)

  let retry = Task { await session.retry() }
  #expect(await insertion.waitUntilInsertionCount(2))
  await session.terminate()
  await retry.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
}

@Test @MainActor
func terminationDuringLastTranscriptPasteCannotPublishALateFailure() async {
  let insertion = MockTextInserter(
    results: [
      .success(.verified),
      .failure(.insertionFailed),
    ],
    insertDelay: .milliseconds(50)
  )
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("paste me"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  let paste = Task { await session.pasteLastTranscript() }
  #expect(await insertion.waitUntilInsertionCount(2))
  await session.terminate()
  await paste.value

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .disabled)
  #expect(snapshot.failure == nil)
}

@Test @MainActor
func lastTranscriptCanBePastedWithoutDuplicatingHistory() async throws {
  let historyDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("VaniLastTranscriptTests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: historyDirectory) }

  let history = TranscriptHistoryStore(directory: historyDirectory)
  let insertion = MockTextInserter(results: [
    .success(.verified),
    .success(.verified),
  ])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("repeat me"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    history: history,
    diagnostics: DiagnosticStore(),
    settings: VaniSettings(historyEnabled: true)
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  await session.pasteLastTranscript()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.hasLastTranscript)
  #expect(insertion.insertedTexts == ["repeat me", "repeat me"])
  #expect(try await history.load().map(\.text) == ["repeat me"])
}

@Test @MainActor
func dictationSessionAppliesConfiguredSnippetsAndSmartFormatting() async throws {
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(
      results: [.success(speechResult("um sign off period next thought question mark"))]
    ),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    settings: VaniSettings(
      snippets: [SnippetEntry(trigger: "sign off", expansion: "Thanks,\nMrinoy")],
      smartFormattingEnabled: true
    )
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  #expect(insertion.insertedTexts == ["Thanks,\nMrinoy. Next thought?"])
}

@Test @MainActor
func dictationSessionInsertsAStandaloneStructuralCommand() async throws {
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("next line"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore(),
    settings: VaniSettings(smartFormattingEnabled: true)
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  #expect(insertion.insertedTexts == ["\n"])
}

@Test @MainActor
func failedLastTranscriptPasteRemainsRecoverableAndRetryable() async throws {
  let insertion = MockTextInserter(results: [
    .success(.verified),
    .failure(.insertionFailed),
    .success(.verified),
  ])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("keep this"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  await session.pasteLastTranscript()

  var snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .insertionFailed)
  #expect(snapshot.recoverableTranscript == "keep this")
  #expect(snapshot.hasLastTranscript)

  await session.retry()
  snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.hasLastTranscript)
  #expect(insertion.insertedTexts == ["keep this", "keep this", "keep this"])
}

@Test @MainActor
func silentCaptureShowsNoticeThenReturnsToReady() async throws {
  let diagnostics = DiagnosticStore()
  let speech = MockSpeechRecognizer(results: [])
  let session = DictationSession(
    audioCapture: MockAudioCapture(
      audio: CapturedAudio(samples: Array(repeating: 0, count: 8_000))
    ),
    speechRecognizer: speech,
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: diagnostics,
    transientFailureDuration: .milliseconds(1)
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(await speech.transcribeCount == 0)
  #expect(await diagnostics.snapshot().contains { $0.code == "noSpeechDetected" })
}

@Test @MainActor
func duplicateStartAndStopEventsDoNotTouchAdaptersTwice() async throws {
  let audio = MockAudioCapture()
  let speech = MockSpeechRecognizer(results: [.success(speechResult("hello"))])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.beginDictation()
  await session.endDictation()
  await session.endDictation()

  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 1)
  #expect(await speech.transcribeCount == 1)
}

@Test @MainActor
func failedTranscriptionRetainsAudioAndRetries() async throws {
  let speech = MockSpeechRecognizer(results: [
    .failure(.transcriptionFailed),
    .success(speechResult("recovered")),
  ])
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()
  #expect(await session.snapshot().failure == .transcriptionFailed)

  await session.retry()

  #expect(await session.snapshot().phase == .ready)
  #expect(await speech.transcribeCount == 2)
  #expect(insertion.insertedTexts == ["recovered"])
}

@Test @MainActor
func unverifiedInsertionRetainsTranscriptWithoutUnsafeAutomaticRetry() async throws {
  let insertion = MockTextInserter(results: [
    .success(.manualPasteRequired)
  ])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("keep me"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  var snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.failure == .insertionUnverified)
  #expect(snapshot.recoverableTranscript == "keep me")

  try await session.copyRecoveredTranscript()
  #expect(insertion.copiedTexts == ["keep me"])

  await session.retry()
  snapshot = await session.snapshot()
  #expect(snapshot.phase == .recoverableError)
  #expect(snapshot.recoverableTranscript == "keep me")
  #expect(insertion.insertedTexts == ["keep me"])

  await session.discardRecovery()
  snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.recoverableTranscript == nil)
}

@Test @MainActor
func verifiedInsertionWithNewerClipboardContentDoesNotBecomeRetryable() async throws {
  let insertion = MockTextInserter(results: [.success(.verifiedClipboardPreserved)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("insert once"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  let snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(insertion.insertedTexts == ["insert once"])
}

@Test @MainActor
func unverifiedAttemptWithPreservedClipboardDoesNotBlockTheNextDictation() async throws {
  let diagnostics = DiagnosticStore()
  let insertion = MockTextInserter(results: [
    .success(.unverifiedClipboardPreserved),
    .success(.verified),
  ])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [
      .success(speechResult("first attempt")),
      .success(speechResult("second attempt")),
    ]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: diagnostics
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.endDictation()

  var snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(snapshot.insertionFeedback == .unconfirmed)
  #expect(
    await diagnostics.snapshot().contains {
      $0.code == "unverified_clipboard_preserved"
    }
  )

  await session.beginDictation()
  await session.endDictation()

  snapshot = await session.snapshot()
  #expect(snapshot.phase == .ready)
  #expect(snapshot.failure == nil)
  #expect(snapshot.insertionFeedback == .verified)
  #expect(insertion.insertedTexts == ["first attempt", "second attempt"])
}

@Test @MainActor
func concurrentStartRequestsOnlyStartOneCapture() async throws {
  let audio = MockAudioCapture(startDelay: .milliseconds(25))
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("hello"))]),
    textInserter: MockTextInserter(results: [.success(.verified)]),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  async let first: Void = session.beginDictation()
  async let second: Void = session.beginDictation()
  _ = await (first, second)

  #expect(await session.snapshot().phase == .listening)
  #expect(await audio.startCount == 1)
}

@Test @MainActor
func releaseDuringCaptureStartupStopsAfterTheMicrophoneStarts() async throws {
  let audio = MockAudioCapture(startDelay: .milliseconds(25))
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: audio,
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("quick release"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  async let start: Void = session.beginDictation()
  #expect(await audio.waitUntilStart())
  await session.endDictation()
  await start

  #expect(await session.snapshot().phase == .ready)
  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 1)
  #expect(insertion.insertedTexts == ["quick release"])
}

@Test @MainActor
func concurrentPreparationRequestsOnlyLoadOneModel() async throws {
  let speech = MockSpeechRecognizer(results: [], modelCheckDelay: .milliseconds(25))
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  async let first = session.prepareModels(allowDownload: false)
  async let second = session.prepareModels(allowDownload: false)
  let results = await (first, second)

  #expect(results.0 != results.1)
  #expect(await session.snapshot().phase == .ready)
  #expect(await speech.prepareCount == 1)
}

@Test @MainActor
func permissionRevocationDuringPreparationReturnsToSetupWithoutInternalFailure() async throws {
  let speech = MockSpeechRecognizer(results: [], pausesPreparation: true)
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  async let preparation = session.prepareModels(allowDownload: false)
  #expect(await speech.waitUntilPreparationStarts())
  #expect(await session.snapshot().phase == .preparing)
  await session.permissionWasRevoked(.microphonePermissionDenied)
  await speech.resumePreparation()
  _ = await preparation

  var snapshot = await session.snapshot()
  #expect(snapshot.phase == .setup)
  #expect(snapshot.failure == .microphonePermissionDenied)

  await session.permissionsWereRestored()
  snapshot = await session.snapshot()
  #expect(snapshot.phase == .setup)
  #expect(snapshot.failure == .microphonePermissionDenied)
}

@Test @MainActor
func restoredPermissionKeepsInterruptedCaptureAvailableForRetry() async throws {
  let insertion = MockTextInserter(results: [.success(.verified)])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: [.success(speechResult("preserved"))]),
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.permissionWasRevoked(.microphonePermissionDenied)
  #expect(await session.snapshot().phase == .recoverableError)
  #expect(await session.snapshot().failure == .recordingInterrupted)

  await session.permissionsWereRestored()

  #expect(await session.snapshot().phase == .recoverableError)
  #expect(await session.snapshot().failure == .recordingInterrupted)

  await session.retry()
  #expect(await session.snapshot().phase == .ready)
  #expect(insertion.insertedTexts == ["preserved"])
}

@Test @MainActor
func readySessionResumesAfterAnAudioRouteChangeWithoutReloadingTheModel() async throws {
  let speech = MockSpeechRecognizer(results: [])
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.audioRouteDidChange()
  #expect(await session.snapshot().phase == .preparing)

  await session.resumeAfterSystemChange()

  #expect(await session.snapshot().phase == .ready)
  #expect(await speech.prepareCount == 1)
}

@Test @MainActor
func fiveHundredSequentialDictationsRemainReadyAndBoundDiagnostics() async throws {
  let count = 500
  let speech = MockSpeechRecognizer(
    results: Array(repeating: .success(speechResult("hello")), count: count)
  )
  let insertion = MockTextInserter(
    results: Array(repeating: .success(.verified), count: count)
  )
  let diagnostics = DiagnosticStore(capacity: 100)
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: speech,
    textInserter: insertion,
    focusProvider: MockFocusProvider(),
    diagnostics: diagnostics
  )

  #expect(await session.prepareModels(allowDownload: false))
  for _ in 0..<count {
    await session.beginDictation()
    await session.endDictation()
  }

  #expect(await session.snapshot().phase == .ready)
  #expect(await speech.transcribeCount == count)
  #expect(insertion.insertedTexts.count == count)
  #expect(await diagnostics.snapshot().count == 100)
}

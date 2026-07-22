import Foundation
import Testing

@testable import VaniCore

private actor MockAudioCapture: AudioCapturing {
  let audio: CapturedAudio
  let startDelay: Duration?
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(
    audio: CapturedAudio = CapturedAudio(samples: Array(repeating: 0.05, count: 8_000)),
    startDelay: Duration? = nil
  ) {
    self.audio = audio
    self.startDelay = startDelay
  }

  func start() async throws {
    startCount += 1
    if let startDelay {
      try await Task.sleep(for: startDelay)
    }
  }

  func stop() async throws -> CapturedAudio {
    stopCount += 1
    return audio
  }

  func cancel() async {}
}

private actor MockSpeechRecognizer: SpeechRecognizing {
  private var results: [Result<SpeechResult, VaniFailure>]
  private let modelCheckDelay: Duration?
  private let prepareDelay: Duration?
  private(set) var prepareCount = 0
  private(set) var transcribeCount = 0

  init(
    results: [Result<SpeechResult, VaniFailure>],
    modelCheckDelay: Duration? = nil,
    prepareDelay: Duration? = nil
  ) {
    self.results = results
    self.modelCheckDelay = modelCheckDelay
    self.prepareDelay = prepareDelay
  }

  func modelsAreInstalled() async -> Bool {
    if let modelCheckDelay {
      try? await Task.sleep(for: modelCheckDelay)
    }
    return true
  }

  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    prepareCount += 1
    if let prepareDelay {
      try await Task.sleep(for: prepareDelay)
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

  func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult {
    transcribeCount += 1
    guard !results.isEmpty else { throw VaniFailure.transcriptionFailed }
    return try results.removeFirst().get()
  }
}

@MainActor
private final class MockFocusProvider: FocusProviding {
  var target = TextTarget(processIdentifier: 42, bundleIdentifier: "test.target")

  func currentTarget() -> TextTarget? { target }
}

@MainActor
private final class MockTextInserter: TextInserting {
  var results: [Result<TextInsertionResult, VaniFailure>]
  private(set) var insertedTexts: [String] = []
  private(set) var copiedTexts: [String] = []

  init(results: [Result<TextInsertionResult, VaniFailure>]) {
    self.results = results
  }

  func insert(_ text: String, into target: TextTarget?) async throws -> TextInsertionResult {
    insertedTexts.append(text)
    guard !results.isEmpty else { throw VaniFailure.insertionFailed }
    return try results.removeFirst().get()
  }

  func copyForManualPaste(_ text: String) throws {
    copiedTexts.append(text)
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
  let speech = MockSpeechRecognizer(results: [], prepareDelay: .milliseconds(25))
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
func restoredPermissionReturnsInterruptedCaptureToReady() async throws {
  let session = DictationSession(
    audioCapture: MockAudioCapture(),
    speechRecognizer: MockSpeechRecognizer(results: []),
    textInserter: MockTextInserter(results: []),
    focusProvider: MockFocusProvider(),
    diagnostics: DiagnosticStore()
  )

  #expect(await session.prepareModels(allowDownload: false))
  await session.beginDictation()
  await session.permissionWasRevoked(.microphonePermissionDenied)
  #expect(await session.snapshot().phase == .recoverableError)

  await session.permissionsWereRestored()

  #expect(await session.snapshot().phase == .ready)
  #expect(await session.snapshot().failure == nil)
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

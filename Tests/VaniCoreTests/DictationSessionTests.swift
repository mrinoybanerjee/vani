import Foundation
import Testing

@testable import VaniCore

private actor MockAudioCapture: AudioCapturing {
  let audio: CapturedAudio
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(audio: CapturedAudio = CapturedAudio(samples: Array(repeating: 0.05, count: 8_000))) {
    self.audio = audio
  }

  func start() async throws {
    startCount += 1
  }

  func stop() async throws -> CapturedAudio {
    stopCount += 1
    return audio
  }

  func cancel() async {}
}

private actor MockSpeechRecognizer: SpeechRecognizing {
  private var results: [Result<SpeechResult, VaniFailure>]
  private(set) var prepareCount = 0
  private(set) var transcribeCount = 0

  init(results: [Result<SpeechResult, VaniFailure>]) {
    self.results = results
  }

  func modelsAreInstalled() async -> Bool { true }

  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    prepareCount += 1
    progress(1)
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
  #expect(!snapshot.hasRecoverableTranscript)
  #expect(insertion.insertedTexts == ["hello world"])
  #expect(await audio.startCount == 1)
  #expect(await audio.stopCount == 1)
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
func unverifiedInsertionRetainsTranscriptForCopyAndRetry() async throws {
  let insertion = MockTextInserter(results: [
    .success(.manualPasteRequired),
    .success(.verified),
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
  #expect(snapshot.phase == .ready)
  #expect(snapshot.recoverableTranscript == nil)
  #expect(insertion.insertedTexts == ["keep me", "keep me"])
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

import Combine
import Foundation
import Testing
import VaniCore

@testable import Vani

private actor MeetingTestRecognizer: SpeechRecognizing {
  var fails = false
  var count = 0
  func setFailure(_ value: Bool) { fails = value }
  func modelsAreInstalled() -> Bool { true }
  func prepare(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
  func transcribe(_ audio: CapturedAudio) throws -> SpeechResult {
    count += 1
    if fails { throw MeetingError.capture("Fixture transcription failed") }
    return SpeechResult(
      text: "We agreed to launch on Monday.", confidence: 1, audioDuration: audio.duration,
      processingDuration: 0)
  }
}

private struct MeetingTestSummarizer: MeetingSummarizing {
  func summarize(_ meeting: MeetingRecord) -> String { "Launch on Monday." }
}

private actor ControlledMeetingSummary: MeetingSummarizing {
  private var continuation: CheckedContinuation<String, Error>?
  private var started: CheckedContinuation<Void, Never>?
  private var didStart = false
  func summarize(_ meeting: MeetingRecord) async throws -> String {
    didStart = true
    started?.resume()
    started = nil
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish(_ result: Result<String, Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

@MainActor
private final class MeetingTestCapture: MeetingAudioRecording {
  var isCapturing = false
  var directory: URL?
  var starts = 0
  var stops = 0
  var failStart = false
  var failStop = false
  var failFlush = false
  var startCallbackFailure = false
  var failureCallback: (@Sendable (String) -> Void)?
  func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) throws {
    starts += 1
    failureCallback = onFailure
    if startCallbackFailure { onFailure("Capture interrupted during startup") }
    if failStart { throw MeetingError.capture("Start failed") }
    self.directory = directory
    isCapturing = true
  }
  func stop() throws {
    stops += 1
    if failStop { throw MeetingError.capture("Stop failed") }
    isCapturing = false
    if failFlush { throw MeetingError.storage("Final flush failed") }
    guard let directory else { return }
    let chunk = MeetingAudioChunk(
      source: .system, offset: 0, samples: [Float](repeating: 0.1, count: 16_000))
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(chunk).write(
      to: directory.appendingPathComponent(chunk.id.uuidString).appendingPathExtension("vani-audio")
    )
  }
}

@Suite(.serialized) @MainActor
struct MeetingModelTests {
  @Test func recordingDrainsFinalChunkAndSummarizesBeforeReturning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = MeetingTestCapture()
    let recognizer = MeetingTestRecognizer()
    var owned = false
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: recognizer,
      summarizer: MeetingTestSummarizer(), makeCapture: { capture },
      reserveSpeech: {
        if owned { return false }
        owned = true
        return true
      }, releaseSpeech: { owned = false })
    await model.start()
    #expect(model.phase == .recording)
    #expect(owned)
    await model.start()
    #expect(capture.starts == 1)
    model.draft?.notes = "My own note stays separate."
    await model.stop()
    #expect(model.phase == .idle)
    #expect(!owned)
    #expect(model.draft?.transcript.count == 1)
    #expect(model.draft?.summary == "Launch on Monday.")
    #expect(model.draft?.notes == "My own note stays separate.")
    #expect(model.draft?.endedAt != nil)
    await model.stop()
    #expect(capture.stops == 1)
    let saved = try await MeetingStore(directory: directory).load().first
    #expect(saved == model.draft)
  }

  @Test func failedStartReleasesOwnershipButFailedStopRetainsIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = MeetingTestCapture()
    capture.failStart = true
    var owned = false
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { capture },
      reserveSpeech: {
        owned = true
        return true
      }, releaseSpeech: { owned = false })
    await model.start()
    #expect(!owned && model.phase == .idle)
    capture.failStart = false
    await model.start()
    capture.failStop = true
    await model.stop()
    #expect(owned && model.phase == .recording)
    #expect(await model.prepareToQuit() == false)
    capture.failStop = false
    #expect(await model.prepareToQuit())
    #expect(!owned)
  }

  @Test func failedTranscriptionPreservesAudioAndRecoveryDoesNotDuplicate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let recognizer = MeetingTestRecognizer()
    let capture = MeetingTestCapture()
    let model = MeetingModel(
      store: store, recognizer: recognizer, summarizer: MeetingTestSummarizer(),
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    await recognizer.setFailure(true)
    await model.stop()
    #expect(model.transcriptionFailed)
    #expect(model.draft?.summary.isEmpty == true)
    let meeting = try #require(model.draft)
    #expect(try await store.pendingAudioFiles(for: meeting).count == 1)
    await recognizer.setFailure(false)
    await model.recoverTranscript()
    #expect(model.draft?.transcript.count == 1)
    #expect(!model.transcriptionFailed)
    await model.recoverTranscript()
    #expect(model.draft?.transcript.count == 1)
    await model.generateSummary()
    #expect(model.draft?.summary == "Launch on Monday.")
  }
  @Test func stoppedCaptureCanRetryFailedFlushWithoutReleasingOwnership() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = MeetingTestCapture()
    var owned = false
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { capture },
      reserveSpeech: {
        owned = true
        return true
      }, releaseSpeech: { owned = false })
    await model.start()
    capture.failFlush = true
    await model.stop()
    #expect(model.phase == .finishing && owned && !capture.isCapturing)
    #expect(await model.prepareToQuit() == false)
    capture.failFlush = false
    await model.stop()
    #expect(model.phase == .idle && !owned)
    #expect(model.draft?.transcript.count == 1)
  }

  @Test func failedTranscriptSaveRetainsAudioUntilDurablyRecovered() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: MeetingTestSummarizer(),
      makeCapture: { MeetingTestCapture() }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    let original = try #require(model.draft)
    let folder = try await store.audioDirectory(for: original.id)
    let file = folder.appendingPathComponent("meeting.json")
    let originalBytes = try Data(contentsOf: file)
    try Data("corrupt".utf8).write(to: file)
    await model.stop()
    #expect(model.transcriptionFailed && model.dirty)
    #expect(model.draft?.transcript.count == 1)
    await model.clearAudio()
    #expect(try await store.pendingAudioFiles(for: original).count == 1)
    #expect(try String(contentsOf: file, encoding: .utf8) == "corrupt")
    try originalBytes.write(to: file)
    await model.recoverTranscript()
    #expect(!model.transcriptionFailed && !model.dirty)
    #expect(try await store.load().first?.transcript.count == 1)
    await model.clearAudio()
    #expect(try await store.pendingAudioFiles(for: original).isEmpty)
  }

  @Test func selectingCurrentMeetingKeepsLatestEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { MeetingTestCapture() },
      reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    await model.stop(summarize: false)
    let stale = try #require(model.meetings.first)
    model.draft?.notes = "Keep this latest edit."
    await model.select(stale)
    #expect(model.draft?.notes == "Keep this latest edit.")
    #expect(!model.dirty)
  }

  @Test func delayedFailureFromPreviousCaptureCannotStopNewMeeting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = MeetingTestCapture()
    let second = MeetingTestCapture()
    var captures = [first, second]
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { captures.removeFirst() },
      reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    let callback = try #require(first.failureCallback)
    await model.stop(summarize: false)
    await model.start()
    let newID = model.draft?.id
    callback("Old capture stopped")
    // Deliver the queued callback on the main actor before checking the new capture.
    await Task { @MainActor in }.value
    #expect(model.phase == .recording && model.draft?.id == newID)
    #expect(second.stops == 0 && model.error == nil)
    await model.stop(summarize: false)
  }

  @Test func editsDuringPersistenceStayDirtyAndBlockNavigationWithoutPausingASR() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { MeetingTestCapture() },
      reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    var edited = false
    let editing = model.$saving.sink { saving in
      if saving && !edited && model.draft?.transcript.isEmpty == false {
        edited = true
        model.draft?.notes = "An edit arriving during transcript persistence."
      }
    }
    await model.stop(summarize: false)
    editing.cancel()
    #expect(edited && !model.transcriptionFailed)
    #expect(model.draft?.notes == "An edit arriving during transcript persistence.")
    model.draft?.notes = "First edit"
    let lateEdit = model.$saving.sink { saving in
      if saving { model.draft?.notes += " + latest edit" }
    }
    #expect(await model.prepareToClose() == false)
    #expect(model.dirty)
    #expect(model.draft?.notes == "First edit + latest edit")
    lateEdit.cancel()
    #expect(await model.prepareToClose())
  }

  @Test func failedCancelledAndStaleGenerationKeepPreviousSummaryAndNotes() async throws {
    for mode in ["failure", "cancel", "edit"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = MeetingStore(directory: directory)
      var meeting = MeetingRecord(title: "Existing summary")
      meeting.endedAt = Date()
      meeting.notes = "My own note"
      meeting.summary = "Previous summary"
      meeting.transcript = [
        .init(id: UUID(), source: .system, offset: 0, duration: 1, text: "We agree to launch.")
      ]
      try await store.save(meeting)
      let summary = ControlledMeetingSummary()
      let model = MeetingModel(
        store: store, recognizer: MeetingTestRecognizer(), summarizer: summary,
        reserveSpeech: { true }, releaseSpeech: {})
      await model.load()
      await model.select(meeting)
      let generation = Task { await model.generateSummary() }
      await summary.waitUntilStarted()
      if mode == "failure" {
        await summary.finish(.failure(MeetingError.summary("Unavailable")))
      } else {
        if mode == "cancel" { model.cancelSummary() } else { model.draft?.notes = "My newer note" }
        await summary.finish(.success("New summary"))
      }
      await generation.value
      #expect(model.phase == .idle && model.error != nil)
      #expect(model.draft?.summary == "Previous summary")
      #expect(model.draft?.notes == (mode == "edit" ? "My newer note" : "My own note"))
      #expect(try await store.load().first?.summary == "Previous summary")
    }
  }

  @Test func systemInterruptionFinishesCaptureAndRetainsNotesWithoutAutoSummary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = MeetingTestCapture()
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { capture }, reserveSpeech: { true },
      releaseSpeech: {})
    await model.start()
    model.draft?.notes = "Before sleep"
    await model.interrupt("Stopped for sleep")
    #expect(model.phase == .idle && !capture.isCapturing)
    #expect(model.draft?.notes == "Before sleep" && model.draft?.transcript.count == 1)
    #expect(model.draft?.summary.isEmpty == true && model.error == "Stopped for sleep")
  }

}

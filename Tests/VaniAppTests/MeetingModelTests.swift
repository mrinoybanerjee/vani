import Combine
import Foundation
import Testing
import VaniCore

@testable import Vani

private actor MeetingTestRecognizer: SpeechRecognizing {
  var fails = false
  var count = 0
  var contexts: [SpeechRecognitionContext] = []
  func setFailure(_ value: Bool) { fails = value }
  func modelsAreInstalled() -> Bool { true }
  func prepare(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
  func transcribe(_ audio: CapturedAudio) throws -> SpeechResult {
    try transcribe(audio, context: .empty)
  }
  func transcribe(_ audio: CapturedAudio, context: SpeechRecognitionContext) throws -> SpeechResult
  {
    count += 1
    contexts.append(context)
    if fails { throw MeetingError.capture("Fixture transcription failed") }
    return SpeechResult(
      text: "We agreed to launch on Monday.", confidence: 1, audioDuration: audio.duration,
      processingDuration: 0)
  }
}

private struct MeetingTestSummarizer: MeetingSummarizing {
  func summarize(_ meeting: MeetingRecord) -> String { "Launch on Monday." }
}

private actor CountingMeetingSummary: MeetingSummarizing {
  private(set) var calls = 0
  func summarize(_ meeting: MeetingRecord) -> String {
    calls += 1
    return "New summary"
  }
}

private actor ControlledMeetingSummary: MeetingSummarizing {
  private var continuation: CheckedContinuation<String, Error>?
  private var started: CheckedContinuation<Void, Never>?
  private var didStart = false
  private(set) var received: MeetingRecord?
  func summarize(_ meeting: MeetingRecord) async throws -> String {
    received = meeting
    didStart = true
    started?.resume()
    started = nil
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation = $0 }
    } onCancel: {
      Task { await self.finish(.failure(CancellationError())) }
    }
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
  /// Chunks written by the final flush: source, offset and samples.
  var finalChunks: [(MeetingAudioSource, TimeInterval, [Float])] = [
    (.system, 0, [Float](repeating: 0.1, count: 16_000))
  ]
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
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    for (source, offset, samples) in finalChunks {
      let chunk = MeetingAudioChunk(source: source, offset: offset, samples: samples)
      try encoder.encode(chunk).write(
        to: directory.appendingPathComponent(chunk.id.uuidString).appendingPathExtension(
          "vani-audio"))
    }
  }
}

@Suite(.serialized) @MainActor
struct MeetingModelTests {
  @Test func failedSaveCanExportThenExplicitlyDiscardWithoutTouchingAudioOrStorage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: MeetingTestSummarizer(),
      makeCapture: { MeetingTestCapture() }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    model.draft?.notes = "Saved meeting note"
    model.discardChanges()
    #expect(model.draft?.notes == "Saved meeting note")  // Recording cannot discard.
    await model.stop(summarize: false)
    let saved = try #require(model.draft)
    let folder = try await store.audioDirectory(for: saved.id)
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "vani-audio" }
    #expect(files.count == 1)
    let audioBefore = try files.map { try Data(contentsOf: $0) }
    let current = folder.appendingPathComponent("meeting.json")
    try Data("corrupt".utf8).write(to: current)
    model.draft?.notes = "Keep this exported edit"
    #expect(await model.save() == false)
    #expect(await model.prepareToClose() == false)
    #expect(await model.prepareToQuit() == false)
    let failure = model.error
    let exported = directory.appendingPathComponent("export.txt")
    try #require(model.draft).exportedText.write(to: exported, atomically: true, encoding: .utf8)
    #expect(try String(contentsOf: exported, encoding: .utf8).contains("Keep this exported edit"))
    model.discardChanges()
    #expect(model.draft == saved && !model.dirty)
    #expect(model.error == failure)
    #expect(await model.prepareToClose())
    #expect(await model.prepareToQuit())
    #expect(try Data(contentsOf: current) == Data("corrupt".utf8))
    #expect(try files.map { try Data(contentsOf: $0) } == audioBefore)
  }

  @Test func discardIsIgnoredWhileSavingOrSummarizing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Original")
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 0, duration: 1, text: "Agreed.")
    ]
    try await store.save(meeting)
    let summary = ControlledMeetingSummary()
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: summary,
      reserveSpeech: { true }, releaseSpeech: {})
    await model.load()
    await model.select(meeting)
    model.draft?.notes = "Save this edit"
    var observedSaving = false
    let saving = model.$saving.dropFirst().sink { value in
      // Published emits before assigning: during the false notification the
      // previous true value still marks the active save, without timing sleeps.
      if !value {
        observedSaving = model.saving
        model.draft?.notes = "Edit during save completion"
        model.discardChanges()
      }
    }
    #expect(await model.save())
    saving.cancel()
    #expect(observedSaving && model.draft?.notes == "Edit during save completion")
    let generation = Task { await model.generateSummary() }
    await summary.waitUntilStarted()
    model.discardChanges()
    #expect(model.draft?.notes == "Edit during save completion")
    await summary.finish(.success("Summary"))
    await generation.value
  }

  @Test func cancelAsSummaryStartsPreventsSummarizerInvocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Original")
    meeting.summary = "Previous summary"
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 0, duration: 1, text: "Agreed.")
    ]
    try await store.save(meeting)
    let summary = CountingMeetingSummary()
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: summary,
      reserveSpeech: { true }, releaseSpeech: {})
    await model.load()
    await model.select(meeting)
    let cancellation = model.$summarizingID.sink { id in
      if id != nil { model.cancelSummary() }
    }
    await model.generateSummary()
    cancellation.cancel()
    #expect(await summary.calls == 0)
    #expect(model.phase == .idle && model.error?.contains("cancelled") == true)
    #expect(model.draft?.summary == "Previous summary")
    #expect(try await store.load().first?.summary == "Previous summary")
  }

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
    for mode in ["failure", "cancel", "transcript"] {
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
        if mode == "cancel" {
          model.cancelSummary()
        } else {
          model.draft?.transcript.append(
            .init(id: UUID(), source: .microphone, offset: 20, duration: 1, text: "Late."))
        }
        await summary.finish(.success("New summary"))
      }
      await generation.value
      #expect(model.phase == .idle && model.error != nil)
      #expect(model.draft?.summary == "Previous summary")
      #expect(model.draft?.notes == "My own note")
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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func audioFiles(_ store: MeetingStore, _ meeting: MeetingRecord) async throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: try await store.audioDirectory(for: meeting.id), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "vani-audio" }
  }

  @Test func meetingChunksUseTheUsersVocabularyAndKeepQuietSpeech() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recognizer = MeetingTestRecognizer()
    let capture = MeetingTestCapture()
    var quiet = [Float](repeating: 0, count: 20 * 16_000)
    for index in 80_000..<88_000 { quiet[index] = 0.012 * Float(sin(Double(index) * 0.07)) }
    capture.finalChunks = [
      (.microphone, 20, quiet),
      (.system, 0, [Float](repeating: 0.001, count: 20 * 16_000)),
    ]
    let correction = LearnedCorrection(
      spoken: "on monday", replacement: "on Tuesday", confirmationCount: 2)
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: recognizer,
      summarizer: MeetingTestSummarizer(), makeCapture: { capture }, reserveSpeech: { true },
      releaseSpeech: {},
      vocabulary: {
        MeetingVocabulary(
          dictionary: [DictionaryEntry(spoken: "launch", replacement: "ship")],
          learnedCorrections: [correction], personalizationEnabled: true)
      })
    await model.start()
    await model.stop(summarize: false)
    // The half-second quiet phrase is transcribed; the faint noise chunk is skipped as silence.
    #expect(await recognizer.count == 1)
    #expect(
      await recognizer.contexts.first?.personalizedTerms.map(\.canonical) == ["on Tuesday"])
    let transcript = try #require(model.draft?.transcript)
    #expect(transcript.map(\.offset) == [0, 20])
    #expect(transcript.first?.text == "")
    #expect(transcript.last?.text == "We agreed to ship on Tuesday.")
    #expect(model.visibleTranscript.map(\.offset) == [20])
  }

  @Test func micEchoIsHiddenButKept() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = MeetingTestCapture()
    capture.finalChunks = [
      (.microphone, 0.5, [Float](repeating: 0.1, count: 16_000)),
      (.system, 0, [Float](repeating: 0.1, count: 16_000)),
    ]
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { capture }, reserveSpeech: { true },
      releaseSpeech: {})
    await model.start()
    await model.stop(summarize: false)
    let transcript = try #require(model.draft?.transcript)
    #expect(transcript.count == 2)
    #expect(transcript.first { $0.source == .microphone }?.isEcho == true)
    #expect(model.visibleTranscript.map(\.source) == [.system])
    #expect(model.echoCount == 1)
    model.showingEchoes = true
    #expect(model.visibleTranscript.map(\.source) == [.system, .microphone])
    #expect(
      try await MeetingStore(directory: directory).load().first?.transcript.filter(\.isEcho).count
        == 1)
  }

  @Test func repeatedlyFailingChunkBecomesAVisibleFailureWithAudioKept() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let recognizer = MeetingTestRecognizer()
    await recognizer.setFailure(true)
    let model = MeetingModel(
      store: store, recognizer: recognizer, summarizer: MeetingTestSummarizer(),
      makeCapture: { MeetingTestCapture() }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    await model.stop()
    #expect(model.transcriptionFailed && model.draft?.transcript.isEmpty == true)
    await model.recoverTranscript()
    #expect(model.transcriptionFailed)
    await model.recoverTranscript()
    // The third failure is recorded truthfully and no longer blocks the meeting.
    #expect(!model.transcriptionFailed && model.failedSegmentCount == 1)
    let meeting = try #require(model.draft)
    #expect(try await store.record(id: meeting.id)?.transcript.first?.isFailed == true)
    #expect(model.visibleTranscript.first?.timeRange == "0:00–0:01")
    await model.clearAudio()
    #expect(model.error?.contains("couldn’t be transcribed") == true)
    #expect(try await audioFiles(store, meeting).count == 1)
    await model.generateSummary()
    #expect(model.draft?.summary == "Launch on Monday.")
    // Recover transcript retries the kept audio once more.
    await recognizer.setFailure(false)
    await model.recoverTranscript()
    #expect(model.failedSegmentCount == 0)
    #expect(model.draft?.transcript.first?.text == "We agreed to launch on Monday.")
    await model.clearAudio()
    #expect(try await audioFiles(store, meeting).isEmpty)
  }

  @Test func confirmedRemovalDeletesAudioOfFailedChunks() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let recognizer = MeetingTestRecognizer()
    await recognizer.setFailure(true)
    let model = MeetingModel(
      store: store, recognizer: recognizer, summarizer: MeetingTestSummarizer(),
      makeCapture: { MeetingTestCapture() }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    await model.stop(summarize: false)
    await model.recoverTranscript()
    await model.recoverTranscript()
    let meeting = try #require(model.draft)
    #expect(try await audioFiles(store, meeting).count == 1)
    await model.clearAudio(includingFailed: true)
    #expect(try await audioFiles(store, meeting).isEmpty)
    #expect(model.draft?.transcript.first?.isFailed == true)
  }

  @Test func summaryRunsInTheBackgroundAndIsSavedToItsOwnMeeting() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var first = MeetingRecord(title: "First")
    first.notes = "Launch matters most"
    first.transcript = [.init(id: UUID(), source: .system, offset: 0, duration: 1, text: "Agreed.")]
    let second = MeetingRecord(title: "Second", createdAt: Date(timeIntervalSinceNow: -60))
    try await store.save(first)
    try await store.save(second)
    let summary = ControlledMeetingSummary()
    let capture = MeetingTestCapture()
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: summary,
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    await model.load()
    await model.select(first)
    let generation = Task { await model.generateSummary() }
    await summary.waitUntilStarted()
    // The user's notes are passed to the summarizer, and the library stays usable.
    #expect(await summary.received?.notes == "Launch matters most")
    #expect(!model.busy && model.summarizingID == first.id)
    await model.select(second)
    #expect(model.draft?.id == second.id)
    model.draft?.notes = "Editing another meeting"
    await model.start()
    #expect(model.phase == .recording)
    await model.stop(summarize: false)
    let recorded = try #require(model.draft)
    await summary.finish(.success("Background summary"))
    await generation.value
    #expect(model.error == nil && model.summarizingID == nil)
    #expect(model.draft?.id == recorded.id && model.draft?.summary.isEmpty == true)
    #expect(try await store.record(id: first.id)?.summary == "Background summary")
    #expect(try await store.record(id: first.id)?.notes == "Launch matters most")
    #expect(try await store.record(id: second.id)?.notes == "Editing another meeting")
    #expect(model.meetings.first { $0.id == first.id }?.summary == "Background summary")
    await model.select(try #require(model.meetings.first { $0.id == first.id }))
    #expect(model.draft?.summary == "Background summary" && !model.dirty)
  }

  @Test func notesEditedWhileSummarizingAreKeptWithTheNewSummary() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Notes")
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 0, duration: 1, text: "Agreed.")
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
    model.draft?.notes = "Written during the summary"
    await summary.finish(.success("Fresh summary"))
    await generation.value
    #expect(model.error == nil && !model.dirty)
    #expect(try await store.record(id: meeting.id)?.summary == "Fresh summary")
    #expect(try await store.record(id: meeting.id)?.notes == "Written during the summary")
  }

  @Test func quittingCancelsASummaryInsteadOfRefusing() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Quit")
    meeting.summary = "Previous summary"
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 0, duration: 1, text: "Agreed.")
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
    #expect(await model.prepareToQuit())
    await generation.value
    #expect(try await store.record(id: meeting.id)?.summary == "Previous summary")
  }

  @Test func refusedActionsExplainThemselves() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var reservable = true
    let capture = MeetingTestCapture()
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { capture },
      reserveSpeech: { reservable }, releaseSpeech: {})
    await model.start()
    let recording = try #require(model.draft)
    await model.select(MeetingRecord())
    #expect(model.error == "Stop the current meeting before opening another.")
    #expect(model.draft?.id == recording.id)
    await model.stop(summarize: false)
    reservable = false
    await model.recoverTranscript()
    #expect(model.error == "Finish dictating, then try again.")
    let unsupported = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {},
      captureSupported: false)
    await unsupported.start()
    #expect(unsupported.error?.contains("macOS 15") == true && capture.starts == 1)
  }

  @Test func quitWhileTranscribingSaysWhy() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: MeetingTestSummarizer(), makeCapture: { MeetingTestCapture() },
      reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    var quit: Task<Bool, Never>?
    let observer = model.$phase.sink { phase in
      if phase == .transcribing && quit == nil { quit = Task { await model.prepareToQuit() } }
    }
    await model.stop(summarize: false)
    observer.cancel()
    #expect(await quit?.value == false)
    #expect(model.error?.contains("finishing this meeting’s transcript") == true)
  }

  @Test func captureThatNeverStartsLeavesNoEmptyMeeting() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let capture = MeetingTestCapture()
    capture.failStart = true
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), summarizer: MeetingTestSummarizer(),
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    #expect(model.error == "Start failed")
    #expect(model.draft == nil && model.meetings.isEmpty)
    #expect(try await store.load().isEmpty)
  }

  @Test func transcriptionFailedDuringSleepIsRetriedAfterWake() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recognizer = MeetingTestRecognizer()
    await recognizer.setFailure(true)
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: recognizer,
      summarizer: MeetingTestSummarizer(), makeCapture: { MeetingTestCapture() },
      reserveSpeech: { true }, releaseSpeech: {}, recoveryRetryDelay: .milliseconds(20))
    await model.start()
    await model.interrupt("Meeting stopped for sleep.")
    #expect(model.transcriptionFailed)
    await recognizer.setFailure(false)
    for _ in 0..<200 where model.transcriptionFailed || model.busy {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.transcriptionFailed)
    #expect(model.draft?.transcript.first?.text == "We agreed to launch on Monday.")
  }

  @Test func deletedMeetingsMoveToRecentlyDeletedAndCanBeRestored() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = MeetingRecord(title: "Retro")
    try await store.save(meeting)
    let model = MeetingModel(
      store: store, recognizer: MeetingTestRecognizer(), reserveSpeech: { true },
      releaseSpeech: {})
    await model.load()
    await model.select(meeting)
    await model.setDeleted(true)
    #expect(model.draft == nil && model.visibleMeetings.isEmpty)
    #expect(try await store.record(id: meeting.id)?.deletedAt != nil)
    await model.showDeleted(true)
    #expect(model.visibleMeetings.map(\.id) == [meeting.id])
    await model.select(try #require(model.visibleMeetings.first))
    await model.setDeleted(false)
    await model.showDeleted(false)
    #expect(model.visibleMeetings.map(\.id) == [meeting.id])
    #expect(try await store.record(id: meeting.id)?.deletedAt == nil)
  }

  @Test func summaryAvailabilityIsAHintThatNeverBlocksRecording() async throws {
    struct Missing: MeetingSummarizing {
      func summarize(_ meeting: MeetingRecord) -> String { "" }
      func availability() -> MeetingSummaryAvailability { .modelMissing }
    }
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: MeetingTestRecognizer(),
      summarizer: Missing(), makeCapture: { MeetingTestCapture() }, reserveSpeech: { true },
      releaseSpeech: {})
    await model.start()
    #expect(model.phase == .recording)
    await model.refreshSummaryAvailability()
    #expect(model.summaryAvailability == .modelMissing)
    await model.stop(summarize: false)
  }
}

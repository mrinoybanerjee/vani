import Foundation
import Testing

@testable import Vani
@testable import VaniCore

/// Returns about 2.5 words per second of audio and records when each chunk is transcribed.
private actor FastMeetingRecognizer: SpeechRecognizing {
  private(set) var calls: [ContinuousClock.Instant] = []
  private static let vocabulary =
    "we should ship the pricing page after the review then follow up with legal about retention and move the launch plan forward next sprint"
    .split(separator: " ").map(String.init)
  func modelsAreInstalled() -> Bool { true }
  func prepare(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
  func transcribe(_ audio: CapturedAudio) throws -> SpeechResult {
    try transcribe(audio, context: .empty)
  }
  func transcribe(_ audio: CapturedAudio, context: SpeechRecognitionContext) throws -> SpeechResult
  {
    calls.append(.now)
    let count = max(1, Int(audio.duration * 2.5))
    let seed = calls.count
    let words = (0..<count).map { Self.vocabulary[($0 * 7 + seed * 13) % Self.vocabulary.count] }
    return SpeechResult(
      text: words.joined(separator: " "), confidence: 1, audioDuration: audio.duration,
      processingDuration: 0)
  }
}

private struct NoSummary: MeetingSummarizing {
  func summarize(_ meeting: MeetingRecord) -> String { "" }
}

/// Alternating turns with 0.3–2 s pauses and an occasional long silence (screen share, reading).
private struct Turn {
  let start: TimeInterval
  let end: TimeInterval
  let source: MeetingAudioSource
  let pitch: Double
}

/// `brisk` models a lively call: 1–8 second turns instead of 2–45 seconds.
private func conversation(duration: TimeInterval, seed: UInt64, brisk: Bool = false) -> [Turn] {
  var random = SeededGenerator(seed: seed)
  var turns: [Turn] = []
  var time = 1.0
  var nextLongSilence = 600.0
  while time < duration {
    if time >= nextLongSilence {
      time += random.uniform(20...90)
      nextLongSilence += random.uniform(600...1200)
    }
    let source: MeetingAudioSource = random.unit() < 0.35 ? .microphone : .system
    let length =
      brisk
      ? random.uniform(1...8)
      : random.unit() < 0.7 ? random.uniform(2...15) : random.uniform(15...45)
    turns.append(
      Turn(
        start: time, end: min(duration, time + length), source: source,
        pitch: random.uniform(110...230)))
    time += length + random.uniform(0.3...2)
  }
  return turns
}

/// Voiced, syllable-modulated tone inside the source's turns; room noise or digital silence
/// outside them. Deterministic per sample, so the delivery order does not change the audio.
private func speechSignal(_ turns: [Turn], noise: Float) -> (inout [Float], TimeInterval, Double)
  -> Void
{
  return { buffer, start, rate in
    var index = turns.firstIndex { $0.end > start } ?? turns.count
    let base = UInt64(start * rate)
    for frame in buffer.indices {
      let time = start + Double(frame) / rate
      while index < turns.count && turns[index].end <= time { index += 1 }
      var value: Float = 0
      if index < turns.count, time >= turns[index].start {
        let phase = 2 * Double.pi * turns[index].pitch * time
        let syllable = sin(Double.pi * 4.2 * time)
        let envelope = 0.2 + 0.8 * syllable * syllable
        value = Float(
          0.1 * envelope * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75)
      }
      if noise > 0 {
        var hash = (base &+ UInt64(frame)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= hash >> 29
        value += noise * (Float(hash & 0xFFFF) / 32768 - 1)
      }
      buffer[frame] = value
    }
  }
}

private let soakDuration: TimeInterval = 2 * 60 * 60
/// One 3-second delivery gap, and ten minutes of Mac audio at 44.1 kHz.
private let soakGap = (start: 2_400.0, end: 2_403.0)
private let soakLowRate = (start: 3_600.0, end: 4_200.0)

/// A two-hour, two-source meeting driven through the production chunker, store and
/// `MeetingModel` drain with a fast fake recognizer. Opt-in: VANI_RUN_LONG_MEETING_SOAK=1.
@Suite(.serialized) @MainActor
struct LongMeetingSoakTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["VANI_RUN_LONG_MEETING_SOAK"] == "1",
      "Two hours of synthetic capture; about a minute in release"))
  func twoHourMeetingStaysWithinLimitsAndLosesNoAudio() async throws {
    guard #available(macOS 15.0, *) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = ResidentMemorySampler()
    let clock = ContinuousClock()
    let started = clock.now
    let recognizer = FastMeetingRecognizer()
    let capture = SyntheticMeetingCapture()
    let store = MeetingStore(directory: root)
    let model = MeetingModel(
      store: store, recognizer: recognizer, summarizer: NoSummary(), makeCapture: { capture },
      reserveSpeech: { true }, releaseSpeech: {}, transcriptionRetryDelay: .zero)
    await model.start()
    #expect(model.phase == .recording)
    let output = try #require(capture.output)
    let directory = try #require(capture.directory)
    let turns = conversation(duration: soakDuration, seed: 11)

    // ScreenCaptureKit's serial queue: runs while the main actor drains saved chunks.
    let callbacks = try await Task.detached {
      var streams = [
        CallbackStream(
          source: .system, frames: 1_024,
          rate: { $0 >= soakLowRate.start && $0 < soakLowRate.end ? 44_100 : 48_000 },
          jitter: 0.003, gaps: [soakGap], end: soakDuration,
          signal: speechSignal(turns.filter { $0.source == .system }, noise: 0)),
        CallbackStream(
          source: .microphone, frames: 480, jitter: 0.001, end: soakDuration,
          signal: speechSignal(turns.filter { $0.source == .microphone }, noise: 0.0008)),
      ]
      return try deliver(&streams, to: output, seed: 5)
    }.value
    let delivered = clock.now
    let liveSegments = model.draft?.transcript.count ?? 0
    await model.stop(summarize: false)
    let finished = clock.now
    let peak = memory.stop()

    #expect(model.error == nil)
    #expect(!model.transcriptionFailed)
    let meeting = try #require(model.draft)
    let chunks = try savedChunks(in: directory)
    let recordSize =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("meeting.json").path)[.size] as? Int ?? 0

    #expect(chunks.count <= 1_440)
    #expect(meeting.transcript.count == chunks.count)
    #expect(Set(meeting.transcript.map(\.id)) == Set(chunks.map(\.id)))
    #expect(meeting.transcript.allSatisfy { !$0.isFailed })
    #expect(recordSize <= MeetingStore.maximumRecordBytes)
    let durations = try chunks.map { try $0.audio().duration }
    #expect(durations.allSatisfy { $0 <= 25 })

    var report = [
      "callbacks \(callbacks)", "chunks \(chunks.count)", "segments \(meeting.transcript.count)",
      "live segments at stop \(liveSegments)",
      String(format: "longest chunk %.2f s", durations.max() ?? 0),
      "record \(recordSize) bytes",
    ]
    for source in [MeetingAudioSource.system, .microphone] {
      let ordered = try chunks.filter { $0.source == source }.sorted { $0.offset < $1.offset }
        .map { (offset: $0.offset, duration: try $0.audio().duration) }
      var covered = 0.0
      var holes: [TimeInterval] = []
      var worstJoin = 0.0
      for (index, chunk) in ordered.enumerated() {
        covered += chunk.duration
        guard index + 1 < ordered.count else { continue }
        let join = ordered[index + 1].offset - (chunk.offset + chunk.duration)
        if join > 0.5 {
          holes.append(chunk.offset + chunk.duration)
        } else {
          worstJoin = max(worstJoin, abs(join))
        }
      }
      let expected = soakDuration - (source == .system ? soakGap.end - soakGap.start : 0)
      let short = ordered.filter { $0.duration < 15 }.count
      report.append(
        String(
          format:
            "%@: %d chunks (%d under 15 s), covered %.3f s of %.0f s, worst join %.4f s, holes %@",
          source.rawValue, ordered.count, short, covered, expected, worstJoin,
          holes.map { String(format: "%.1f", $0) }.description))
      // Offsets are monotonic and every captured second is in exactly one chunk.
      #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0.offset < $1.offset })
      #expect(abs(covered - expected) < 0.2)
      #expect(worstJoin < 0.05)
      #expect(holes.count == (source == .system ? 1 : 0))
    }

    let calls = await recognizer.calls
    let intervals = zip(calls, calls.dropFirst()).map { ($1 - $0) / .milliseconds(1) }
    report.append(
      String(
        format: "chunk cycle p50/p95: first 100 %.1f/%.1f ms, last 100 %.1f/%.1f ms",
        percentile(Array(intervals.prefix(100)), 0.5),
        percentile(Array(intervals.prefix(100)), 0.95),
        percentile(Array(intervals.suffix(100)), 0.5),
        percentile(Array(intervals.suffix(100)), 0.95)))

    // Re-save the final transcript one segment at a time, as the live drain does.
    let replay = MeetingStore(directory: root.appendingPathComponent("replay"))
    var record = MeetingRecord(title: meeting.title)
    var saves: [Double] = []
    for segment in meeting.transcript.sorted(by: { $0.offset < $1.offset }) {
      record.transcript.append(segment)
      let begin = clock.now
      try await replay.save(record)
      saves.append((clock.now - begin) / .milliseconds(1))
    }
    let early = Array(saves.prefix(100))
    let late = Array(saves.suffix(100))
    report.append(
      String(
        format: "store.save p50/p95: first 100 %.2f/%.2f ms, last 100 %.2f/%.2f ms",
        percentile(early, 0.5), percentile(early, 0.95), percentile(late, 0.5),
        percentile(late, 0.95)))
    #expect(percentile(late, 0.95) < 100)

    let (echoSeconds, marked, expectedEchoes) = echoMarkingOverFullTranscript(meeting.transcript)
    report.append(
      String(
        format: "echo marking: %d segments in %.1f ms, %d of %d echo copies marked",
        meeting.transcript.count, echoSeconds * 1000, marked, expectedEchoes))
    #expect(marked == expectedEchoes)
    #expect(echoSeconds < 5)

    report.append(
      String(
        format: "wall %.1f s (delivery %.1f s, stop and final drain %.1f s), peak RSS %@",
        (finished - started) / .seconds(1), (delivered - started) / .seconds(1),
        (finished - delivered) / .seconds(1), mebibytes(peak)))
    for line in report { print("VANI_LONG_SOAK \(line)") }
  }

  /// If Mac audio callbacks stopped during silence instead of carrying zeros, every pause
  /// longer than 0.5 s would end a chunk. This measures how many chunks two hours would
  /// produce then, against the 1,440 chunk and segment limit.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["VANI_RUN_LONG_MEETING_SOAK"] == "1",
      "Two hours of synthetic capture per conversation"))
  func macAudioThatPausesDuringSilenceMultipliesChunks() async throws {
    guard #available(macOS 15.0, *) else { return }
    var report: [String] = []
    for brisk in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let turns = conversation(duration: soakDuration, seed: 11, brisk: brisk)
      let remote = turns.filter { $0.source == .system }
      let output = MeetingStreamOutput(
        directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _, _ in })
      try await Task.detached {
        // No callbacks between remote turns (0.2 s release tail), as if nothing played.
        var silences: [(start: TimeInterval, end: TimeInterval)] = []
        var previousEnd = 0.0
        for turn in remote {
          if turn.start - (previousEnd + 0.2) > 0.5 {
            silences.append((previousEnd + 0.2, turn.start))
          }
          previousEnd = turn.end
        }
        var streams = [
          CallbackStream(
            source: .system, frames: 1_024, gaps: silences, end: soakDuration,
            signal: speechSignal(remote, noise: 0)),
          CallbackStream(
            source: .microphone, frames: 480, end: soakDuration,
            signal: speechSignal(turns.filter { $0.source == .microphone }, noise: 0.0008)),
        ]
        _ = try deliver(&streams, to: output, seed: 5)
        try output.finish()
      }.value
      let chunks = try savedChunks(in: directory)
      let system = chunks.filter { $0.source == .system }.count
      #expect(chunks.count <= 1_440)
      report.append(
        "\(brisk ? "brisk" : "default") conversation: \(remote.count) remote turns, "
          + "\(chunks.count) chunks (\(system) Mac audio, \(chunks.count - system) microphone)")
    }
    for line in report { print("VANI_LONG_SOAK paused delivery, \(line)") }
  }

  /// Rebuilds the full transcript through `MeetingEchoDetector` in arrival order, where half of
  /// the speaking microphone segments repeat the overlapping Mac audio word for word.
  private func echoMarkingOverFullTranscript(_ transcript: [MeetingTranscriptSegment]) -> (
    TimeInterval, Int, Int
  ) {
    var random = SeededGenerator(seed: 3)
    let words = (0..<400).map { "word\($0)" }
    let ordered = transcript.sorted { $0.offset < $1.offset }
    var texts: [UUID: String] = [:]
    for segment in ordered where segment.source == .system && !segment.text.isEmpty {
      texts[segment.id] = (0..<max(8, Int(segment.duration * 2.5))).map { _ in
        words[Int(random.next() % 400)]
      }.joined(separator: " ")
    }
    var expected = 0
    for segment in ordered where segment.source == .microphone && !segment.text.isEmpty {
      let overlapping = ordered.filter {
        $0.source == .system && texts[$0.id] != nil && MeetingEchoDetector.overlaps(segment, $0)
      }
      if !overlapping.isEmpty && random.unit() < 0.5 {
        texts[segment.id] = overlapping.compactMap { texts[$0.id] }.joined(separator: " ")
        expected += 1
      } else {
        texts[segment.id] = "mine " + segment.text
      }
    }
    var detector = MeetingEchoDetector()
    var result: [MeetingTranscriptSegment] = []
    let clock = ContinuousClock()
    let begin = clock.now
    for segment in ordered {
      result = detector.adding(
        MeetingTranscriptSegment(
          id: segment.id, source: segment.source, offset: segment.offset,
          duration: segment.duration, text: texts[segment.id] ?? ""), to: result)
    }
    let elapsed = (clock.now - begin) / .seconds(1)
    return (elapsed, result.filter(\.isEcho).count, expected)
  }
}

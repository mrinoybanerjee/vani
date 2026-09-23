import Foundation
import Testing

@testable import Vani
@testable import VaniCore

// Opt-in: a ~30-minute, six-speaker "meeting" built from LibriSpeech test-clean, delivered at
// 48 kHz through the production chunker and transcribed by `MeetingModel` with the real
// Parakeet Unified model. Requires VANI_LIBRISPEECH_DIR (the `test-clean` folder) and
// VANI_UNIFIED_MODEL_DIR. VANI_LONG_MEETING_OUTPUT, when set, receives the meeting record.

private struct Utterance {
  let url: URL
  let text: String
}

/// One utterance placed on a 48 kHz timeline.
private struct Placement {
  let source: MeetingAudioSource
  let turn: Int
  let start: Int
  let samples: [Float]
  let text: String
  var end: Int { start + samples.count }
  var seconds: ClosedRange<TimeInterval> { Double(start) / 48_000...Double(end) / 48_000 }
}

private struct SyntheticMeeting {
  let placements: [Placement]
  let duration: TimeInterval
  /// 16 kHz audio and reference text of each turn, for transcription in isolation.
  let turns: [(source: MeetingAudioSource, audio: [Float], text: String)]
}

private func librispeech(_ root: URL, speaker: String) throws -> [Utterance] {
  let folder = root.appendingPathComponent(speaker)
  var result: [Utterance] = []
  for chapter in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
    let directory = folder.appendingPathComponent(chapter)
    let lines = try String(
      contentsOf: directory.appendingPathComponent("\(speaker)-\(chapter).trans.txt"),
      encoding: .utf8
    ).split(separator: "\n")
    for line in lines {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      result.append(
        Utterance(
          url: directory.appendingPathComponent("\(parts[0]).flac"), text: String(parts[1])))
    }
  }
  return result
}

/// Five remote speakers on Mac audio and one local speaker on the microphone, alternating
/// turns of one to three utterances with 0.25–0.6 s pauses inside a turn and 0.3–2 s between.
private func buildMeeting(root: URL, minutes: Double) throws -> SyntheticMeeting {
  let remote = ["1089", "1188", "121", "1221", "1284"]
  let local = "1320"
  var queues: [String: [Utterance]] = [:]
  for speaker in remote + [local] { queues[speaker] = try librispeech(root, speaker: speaker) }
  var random = SeededGenerator(seed: 21)
  var placements: [Placement] = []
  var turns: [(MeetingAudioSource, [Float], String)] = []
  var time = 0.5
  var previous = ""
  var turn = 0
  while time < minutes * 60 {
    let available = remote.filter { $0 != previous && queues[$0]?.isEmpty == false }
    let speaker =
      random.unit() < 0.25 && queues[local]?.isEmpty == false && previous != local
      ? local : available[Int(random.next() % UInt64(available.count))]
    let source: MeetingAudioSource = speaker == local ? .microphone : .system
    var turnAudio: [Float] = []
    var turnText: [String] = []
    let count = 1 + Int(random.next() % 3)
    for index in 0..<count {
      guard let utterance = queues[speaker]?.first else { break }
      queues[speaker]?.removeFirst()
      let original = try AudioFileLoader.load(utterance.url).samples
      let upsampled = try SampleRateConverter.convert(original, from: 16_000, to: 48_000)
      placements.append(
        Placement(
          source: source, turn: turn, start: Int(time * 48_000), samples: upsampled,
          text: utterance.text))
      turnAudio += original
      turnText.append(utterance.text)
      time += Double(upsampled.count) / 48_000
      if index + 1 < count {
        let pause = random.uniform(0.25...0.6)
        turnAudio += [Float](repeating: 0, count: Int(pause * 16_000))
        time += pause
      }
    }
    turns.append((source, turnAudio, turnText.joined(separator: " ")))
    time += random.uniform(0.3...2)
    previous = speaker
    turn += 1
  }
  return SyntheticMeeting(
    placements: placements, duration: time,
    turns: turns.map { (source: $0.0, audio: $0.1, text: $0.2) })
}

/// Adds `gain` times the placements that overlap a 48 kHz buffer starting at `first`,
/// each shifted later by its delay.
private func mix(
  _ buffer: inout [Float], first: Int, _ placements: [Placement], gain: Float, delays: [Int]
) {
  for (index, placement) in placements.enumerated() {
    let start = placement.start + delays[index]
    guard start < first + buffer.count, start + placement.samples.count > first else { continue }
    let lower = max(first, start)
    let upper = min(first + buffer.count, start + placement.samples.count)
    for position in lower..<upper {
      buffer[position - first] += gain * placement.samples[position - start]
    }
  }
}

private let speechEnvironment = ProcessInfo.processInfo.environment

private struct MeetingRun {
  let meeting: MeetingRecord
  let seconds: TimeInterval
  let peak: UInt64
}

@Suite(.serialized) @MainActor
struct LongMeetingSpeechTests {
  @Test(
    .enabled(
      if: speechEnvironment["VANI_LIBRISPEECH_DIR"] != nil
        && speechEnvironment["VANI_UNIFIED_MODEL_DIR"] != nil,
      "Requires LibriSpeech test-clean and a verified Parakeet Unified model"))
  func thirtyMinuteMeetingMatchesIsolatedAccuracyAndMarksEcho() async throws {
    guard #available(macOS 15.0, *) else { return }
    let root = URL(fileURLWithPath: try #require(speechEnvironment["VANI_LIBRISPEECH_DIR"]))
    let modelDirectory = URL(
      fileURLWithPath: try #require(speechEnvironment["VANI_UNIFIED_MODEL_DIR"]),
      isDirectory: true)
    let built = try buildMeeting(root: root, minutes: 30)
    let recognizer = FluidAudioSpeechRecognizer(unifiedModelDirectory: modelDirectory)
    try await recognizer.prepare { _ in }
    #expect(await recognizer.activeModel() == .parakeetUnified)
    var report = [
      String(
        format: "meeting %.1f min, %d turns, %d utterances (%d on the microphone)",
        built.duration / 60, built.turns.count, built.placements.count,
        built.placements.filter { $0.source == .microphone }.count)
    ]

    // Accuracy ceiling: every turn transcribed alone, straight from its 16 kHz source.
    let clock = ContinuousClock()
    var isolated: [MeetingAudioSource: [String]] = [:]
    let isolationStart = clock.now
    for turn in built.turns {
      let result = try await recognizer.transcribe(CapturedAudio(samples: turn.audio))
      isolated[turn.source, default: []].append(result.text)
    }
    report.append(
      String(
        format: "isolated turns transcribed in %.1f s", (clock.now - isolationStart) / .seconds(1)))

    let own = built.placements.filter { $0.source == .microphone }
    let remote = built.placements.filter { $0.source == .system }
    let clean = try await run(
      built, recognizer: recognizer, echoDelays: nil, clock: clock)
    var references: [MeetingAudioSource: String] = [:]
    for source in [MeetingAudioSource.system, .microphone] {
      let reference = built.placements.filter { $0.source == source }.map(\.text)
        .joined(separator: " ")
      references[source] = reference
      let segments = clean.meeting.transcript.filter { $0.source == source && !$0.isFailed }
        .sorted { $0.offset < $1.offset }
      let pipeline = WordErrorRate.rate(
        reference: reference, hypothesis: segments.map(\.text).joined(separator: " "))
      let alone = WordErrorRate.rate(
        reference: reference, hypothesis: (isolated[source] ?? []).joined(separator: " "))
      let speech = built.placements.filter { $0.source == source }
      let cutsInsideSpeech = segments.dropLast().filter { segment in
        let cut = segment.offset + segment.duration
        return speech.contains {
          $0.seconds.lowerBound + 0.05 < cut && cut < $0.seconds.upperBound - 0.05
        }
      }.count
      report.append(
        String(
          format:
            "%@: pipeline WER %.2f%% (%d/%d), isolated turns %.2f%% (%d/%d), %d chunks, %d transcribed, %d cuts inside an utterance",
          source.rawValue, pipeline.rate * 100, pipeline.errors, pipeline.words, alone.rate * 100,
          alone.errors, alone.words, segments.count, segments.filter { !$0.text.isEmpty }.count,
          cutsInsideSpeech))
      #expect(pipeline.rate <= alone.rate + 0.01)
      if let output = speechEnvironment["VANI_LONG_MEETING_OUTPUT"] {
        let folder = URL(fileURLWithPath: output)
        for (name, text) in [
          ("reference", reference), ("pipeline", segments.map(\.text).joined(separator: "\n")),
          ("isolated", (isolated[source] ?? []).joined(separator: "\n")),
        ] {
          try text.write(
            to: folder.appendingPathComponent("\(source.rawValue)-\(name).txt"), atomically: true,
            encoding: .utf8)
        }
      }
    }
    #expect(clean.meeting.transcript.allSatisfy { !$0.isFailed })
    #expect(clean.meeting.transcript.allSatisfy { !$0.isEcho })
    report.append(
      String(
        format: "clean run: %.1f s wall for %.1f min, peak RSS %@", clean.seconds,
        built.duration / 60, mebibytes(clean.peak)))
    if let output = speechEnvironment["VANI_LONG_MEETING_OUTPUT"] {
      let file = URL(fileURLWithPath: output).appendingPathComponent(
        "librispeech-30min-meeting.json")
      try JSONEncoder().encode(clean.meeting).write(to: file)
      report.append("record written to \(file.path)")
    }

    // No headphones: the microphone also hears the remote speakers at -20 dB, 30–120 ms late.
    var random = SeededGenerator(seed: 9)
    let delays = remote.map { _ in Int(random.uniform(0.03...0.12) * 48_000) }
    let echo = try await run(built, recognizer: recognizer, echoDelays: delays, clock: clock)
    let microphone = echo.meeting.transcript.filter { $0.source == .microphone && !$0.isFailed }
    // Seconds of the user's own utterances inside a chunk. LibriSpeech files start and end
    // with up to half a second of silence, so a smaller overlap holds none of the user's words.
    let ownSeconds = { (segment: MeetingTranscriptSegment) in
      own.map {
        max(
          0,
          min($0.seconds.upperBound, segment.offset + segment.duration)
            - max($0.seconds.lowerBound, segment.offset))
      }.reduce(0, +)
    }
    let speaksOwn = { (segment: MeetingTranscriptSegment) in ownSeconds(segment) >= 0.5 }
    let echoOnly = microphone.filter {
      !speaksOwn($0) && MeetingEchoDetector.normalizedWords($0.text).count >= 8
    }
    let marked = echoOnly.filter(\.isEcho).count
    let hiddenOwn = microphone.filter { speaksOwn($0) && $0.isEcho }.count
    let touchingOwn = microphone.filter { ownSeconds($0) > 0 && !speaksOwn($0) }
    let visible = microphone.filter { !$0.isEcho }.sorted { $0.offset < $1.offset }
      .map(\.text).joined(separator: " ")
    let ownReference = WordErrorRate.words(references[.microphone] ?? "")
    let recall =
      Double(WordErrorRate.align(ownReference, WordErrorRate.words(visible)).matched)
      / Double(max(1, ownReference.count))
    let isolatedRecall =
      Double(
        WordErrorRate.align(
          ownReference, WordErrorRate.words((isolated[.microphone] ?? []).joined(separator: " "))
        ).matched) / Double(max(1, ownReference.count))
    let echoSystem = WordErrorRate.rate(
      reference: references[.system] ?? "",
      hypothesis: echo.meeting.transcript.filter { $0.source == .system }
        .sorted { $0.offset < $1.offset }.map(\.text).joined(separator: " "))
    report.append(
      String(
        format:
          "echo run: %d microphone chunks, %d echo-only with 8+ words, %d marked; %d chunks with the user's speech, %d of them hidden (%d more touch only silence around the user's turn, %d of those hidden); user words visible %.2f%% (isolated %.2f%%); Mac audio WER %.2f%%; %.1f s wall, peak RSS %@",
        microphone.count, echoOnly.count, marked, microphone.filter(speaksOwn).count, hiddenOwn,
        touchingOwn.count, touchingOwn.filter(\.isEcho).count,
        recall * 100, isolatedRecall * 100, echoSystem.rate * 100, echo.seconds,
        mebibytes(echo.peak)))
    #expect(hiddenOwn == 0)
    #expect(recall >= isolatedRecall - 0.02)
    #expect(Double(marked) >= 0.8 * Double(echoOnly.count))
    for line in report { print("VANI_LONG_SPEECH \(line)") }
  }

  /// Records the meeting through `MeetingModel`, delivering ScreenCaptureKit-shaped 48 kHz
  /// callbacks (1,024 frames of Mac audio, 480 of microphone) while the model transcribes.
  @available(macOS 15.0, *)
  private func run(
    _ built: SyntheticMeeting, recognizer: FluidAudioSpeechRecognizer, echoDelays: [Int]?,
    clock: ContinuousClock
  ) async throws -> MeetingRun {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ResidentMemorySampler()
    let started = clock.now
    let capture = SyntheticMeetingCapture()
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: recognizer,
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    #expect(model.phase == .recording)
    let output = try #require(capture.output)
    let remote = built.placements.filter { $0.source == .system }
    let own = built.placements.filter { $0.source == .microphone }
    let duration = built.duration
    _ = try await Task.detached {
      var streams = [
        CallbackStream(
          source: .system, frames: 1_024, jitter: 0.002, end: duration,
          signal: { buffer, time, _ in
            mix(
              &buffer, first: Int((time * 48_000).rounded()), remote, gain: 1,
              delays: [Int](repeating: 0, count: remote.count))
          }),
        CallbackStream(
          source: .microphone, frames: 480, jitter: 0.001, end: duration,
          signal: { buffer, time, _ in
            let first = Int((time * 48_000).rounded())
            mix(
              &buffer, first: first, own, gain: 1, delays: [Int](repeating: 0, count: own.count))
            if let echoDelays {
              mix(&buffer, first: first, remote, gain: 0.1, delays: echoDelays)
            }
            for index in buffer.indices {
              var hash = UInt64(first + index) &* 0x9E37_79B9_7F4A_7C15
              hash ^= hash >> 29
              buffer[index] += 0.0005 * (Float(hash & 0xFFFF) / 32768 - 1)
            }
          }),
      ]
      return try deliver(&streams, to: output, seed: 17)
    }.value
    await model.stop(summarize: false)
    let seconds = (clock.now - started) / .seconds(1)
    #expect(model.error == nil)
    return MeetingRun(meeting: try #require(model.draft), seconds: seconds, peak: memory.stop())
  }
}

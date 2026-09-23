import Foundation
import Testing

@testable import Vani
@testable import VaniCore

// Opt-in: real recorded meetings from the AMI Meeting Corpus (CC BY 4.0), transcribed through
// Vani's meeting path. The 16 kHz headset mix is upsampled to 48 kHz and delivered as
// ScreenCaptureKit-shaped Mac-audio callbacks to the production `MeetingStreamOutput`, then
// drained by `MeetingModel` with the real Parakeet Unified model. WER is measured against the
// AMI manual word transcripts of all speakers in start-time order.
//
// VANI_AMI_DIR: folder with `audio/<ID>.Mix-Headset.wav` and the AMI manual annotations
// (`annotations/words/<ID>.<speaker>.words.xml`). VANI_AMI_OUTPUT receives `<ID>.meeting.json`
// (the record Vani saved) and the reference and hypothesis texts. VANI_AMI_MEETINGS optionally
// lists meeting IDs separated by commas.

private let amiEnvironment = ProcessInfo.processInfo.environment

enum AMICorpus {
  static let defaultMeetings = [
    "ES2002a", "ES2002b", "ES2002c", "ES2002d", "ES2004a", "IS1009a", "TS3003a",
  ]
  /// Hesitations and backchannels the reference spells out but ASR usually omits, after
  /// `WordErrorRate.words` normalization ("mm-hmm" becomes "mm hmm").
  static let fillers: Set<String> = [
    "um", "uh", "uhm", "hum", "mm", "mmm", "hmm", "huh", "er", "erm", "ah",
  ]

  struct Word {
    let start: Double
    let text: String
  }

  /// Every non-punctuation word of every speaker, in start-time order.
  static func referenceWords(meeting: String, annotations: URL) throws -> [Word] {
    let folder = annotations.appendingPathComponent("words")
    var words: [Word] = []
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    where name.hasPrefix(meeting + ".") && name.hasSuffix(".words.xml") {
      let parser = WordsParser()
      let xml = XMLParser(contentsOf: folder.appendingPathComponent(name))
      xml?.delegate = parser
      guard xml?.parse() == true else { throw MeetingError.invalidData }
      words += parser.words
    }
    return words.enumerated().sorted {
      $0.element.start == $1.element.start
        ? $0.offset < $1.offset : $0.element.start < $1.element.start
    }.map(\.element)
  }

  private final class WordsParser: NSObject, XMLParserDelegate {
    var words: [Word] = []
    private var current: (start: Double, text: String)?

    func parser(
      _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      guard element == "w", attributes["punc"] != "true",
        let start = attributes["starttime"].flatMap(Double.init)
      else { return }
      current = (start, "")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      current?.text += string
    }

    func parser(
      _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      guard element == "w", let word = current else { return }
      current = nil
      let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { words.append(Word(start: word.start, text: text)) }
    }
  }

  static func withoutFillers(_ words: [String]) -> [String] {
    words.filter { !fillers.contains($0) }
  }
}

@Suite(.serialized) @MainActor
struct AMIMeetingTests {
  @Test(
    .enabled(
      if: amiEnvironment["VANI_AMI_DIR"] != nil && amiEnvironment["VANI_UNIFIED_MODEL_DIR"] != nil
        && amiEnvironment["VANI_AMI_OUTPUT"] != nil,
      "Requires AMI headset-mix audio, AMI annotations and a verified Parakeet Unified model"))
  func realMeetingsTranscribeThroughTheMeetingPath() async throws {
    guard #available(macOS 15.0, *) else { return }
    let root = URL(fileURLWithPath: try #require(amiEnvironment["VANI_AMI_DIR"]))
    let output = URL(fileURLWithPath: try #require(amiEnvironment["VANI_AMI_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let recognizer = FluidAudioSpeechRecognizer(
      unifiedModelDirectory: URL(
        fileURLWithPath: try #require(amiEnvironment["VANI_UNIFIED_MODEL_DIR"]), isDirectory: true))
    try await recognizer.prepare { _ in }
    #expect(await recognizer.activeModel() == .parakeetUnified)
    let meetings =
      amiEnvironment["VANI_AMI_MEETINGS"]?.split(separator: ",").map(String.init)
      ?? AMICorpus.defaultMeetings
    var totals = (errors: 0, words: 0, fillerErrors: 0, fillerWords: 0)
    for id in meetings {
      let clock = ContinuousClock()
      let audio = try AudioFileLoader.load(
        root.appendingPathComponent("audio/\(id).Mix-Headset.wav"))
      let upsampled = try SampleRateConverter.convert(audio.samples, from: 16_000, to: 48_000)
      let duration = Double(upsampled.count) / 48_000
      let memory = ResidentMemorySampler()
      let started = clock.now
      let meeting = try await transcribe(upsampled, recognizer: recognizer, title: "AMI \(id)")
      let seconds = (clock.now - started) / .seconds(1)
      let peak = memory.stop()
      let reference = try AMICorpus.referenceWords(
        meeting: id, annotations: root.appendingPathComponent("annotations")
      )
      .map(\.text).joined(separator: " ")
      let segments = meeting.transcript.filter { $0.source == .system && !$0.isFailed }
        .sorted { $0.offset < $1.offset }
      let hypothesis = segments.map(\.text).joined(separator: " ")
      let referenceWords = WordErrorRate.words(reference)
      let hypothesisWords = WordErrorRate.words(hypothesis)
      let raw = WordErrorRate.align(referenceWords, hypothesisWords).errors
      let cleanReference = AMICorpus.withoutFillers(referenceWords)
      let clean = WordErrorRate.align(cleanReference, AMICorpus.withoutFillers(hypothesisWords))
        .errors
      totals.errors += raw
      totals.words += referenceWords.count
      totals.fillerErrors += clean
      totals.fillerWords += cleanReference.count
      #expect(meeting.transcript.allSatisfy { !$0.isFailed })
      try JSONEncoder().encode(meeting).write(
        to: output.appendingPathComponent("\(id).meeting.json"))
      try reference.write(
        to: output.appendingPathComponent("\(id).reference.txt"), atomically: true,
        encoding: .utf8)
      try segments.map { "[\(meetingTimestamp($0.offset))] \($0.text)" }.joined(separator: "\n")
        .write(
          to: output.appendingPathComponent("\(id).hypothesis.txt"), atomically: true,
          encoding: .utf8)
      print(
        String(
          format:
            "VANI_AMI %@: %.1f min, %d chunks (%d with speech), WER %.2f%% (%d/%d), without fillers %.2f%% (%d/%d), %.1f s wall (%.0fx real time), peak RSS %@",
          id, duration / 60, segments.count, segments.filter { !$0.text.isEmpty }.count,
          Double(raw) / Double(max(1, referenceWords.count)) * 100, raw, referenceWords.count,
          Double(clean) / Double(max(1, cleanReference.count)) * 100, clean, cleanReference.count,
          seconds, duration / seconds, mebibytes(peak)))
    }
    print(
      String(
        format: "VANI_AMI total: WER %.2f%% (%d/%d), without fillers %.2f%% (%d/%d)",
        Double(totals.errors) / Double(max(1, totals.words)) * 100, totals.errors, totals.words,
        Double(totals.fillerErrors) / Double(max(1, totals.fillerWords)) * 100,
        totals.fillerErrors, totals.fillerWords))
  }

  /// Delivers the mix as Mac audio (1,024-frame callbacks) and a near-silent microphone
  /// (480-frame callbacks of room noise) while `MeetingModel` transcribes live.
  @available(macOS 15.0, *)
  private func transcribe(
    _ samples: [Float], recognizer: FluidAudioSpeechRecognizer, title: String
  ) async throws -> MeetingRecord {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = SyntheticMeetingCapture()
    let model = MeetingModel(
      store: MeetingStore(directory: directory), recognizer: recognizer,
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    await model.start()
    #expect(model.phase == .recording)
    model.draft?.title = title
    let output = try #require(capture.output)
    let duration = Double(samples.count) / 48_000
    _ = try await Task.detached {
      var streams = [
        CallbackStream(
          source: .system, frames: 1_024, jitter: 0.002, end: duration,
          signal: { buffer, time, _ in
            let first = Int((time * 48_000).rounded())
            for index in buffer.indices where first + index < samples.count {
              buffer[index] = samples[first + index]
            }
          }),
        CallbackStream(
          source: .microphone, frames: 480, jitter: 0.001, end: duration,
          signal: { buffer, time, _ in
            let first = Int((time * 48_000).rounded())
            for index in buffer.indices {
              var hash = UInt64(first + index) &* 0x9E37_79B9_7F4A_7C15
              hash ^= hash >> 29
              buffer[index] = 0.0005 * (Float(hash & 0xFFFF) / 32768 - 1)
            }
          }),
      ]
      return try deliver(&streams, to: output, seed: 23)
    }.value
    await model.stop(summarize: false)
    #expect(model.error == nil)
    return try #require(model.draft)
  }
}

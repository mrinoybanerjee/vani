import Foundation

/// The user's dictation vocabulary, applied to meeting chunks. Snippets are never expanded in
/// meetings and Smart Formatting stays off: a transcript records what was said.
public struct MeetingVocabulary: Sendable, Equatable {
  public var dictionary: [DictionaryEntry]
  public var learnedCorrections: [LearnedCorrection]
  public var personalizationEnabled: Bool

  public init(
    dictionary: [DictionaryEntry] = [], learnedCorrections: [LearnedCorrection] = [],
    personalizationEnabled: Bool = false
  ) {
    self.dictionary = dictionary
    self.learnedCorrections = learnedCorrections
    self.personalizationEnabled = personalizationEnabled
  }

  public static let empty = MeetingVocabulary()

  public var recognitionContext: SpeechRecognitionContext {
    guard personalizationEnabled else { return .empty }
    return SpeechRecognitionContext(
      personalizedTerms: PersonalizationEngine().activeAcousticTerms(
        corrections: learnedCorrections, applicationBundleIdentifier: nil,
        manualDictionary: dictionary, snippets: []))
  }

  public func process(_ text: String) -> String {
    TextPipeline().process(
      text, dictionary: dictionary, snippets: [], smartFormattingEnabled: false,
      learnedCorrections: personalizationEnabled ? learnedCorrections : [],
      applicationBundleIdentifier: nil)
  }
}

/// Loudest RMS across non-overlapping 30 ms frames. A whole-chunk average hides a short quiet
/// phrase inside 20 seconds of silence; one frame of speech energy is enough to transcribe.
public func loudestFrameRMS(_ samples: [Float], sampleRate: Int = CapturedAudio.targetSampleRate)
  -> Float
{
  let frame = max(1, sampleRate * 30 / 1000)
  var loudest: Float = 0
  var start = 0
  while start < samples.count {
    let end = min(start + frame, samples.count)
    var sum: Float = 0
    for index in start..<end { sum += samples[index] * samples[index] }
    loudest = max(loudest, (sum / Float(end - start)).squareRoot())
    start = end
  }
  return loudest
}

/// Text-based, conservative speaker-echo detection. Without headphones the microphone hears
/// remote speech that ScreenCaptureKit also captures as Mac audio, so the same words appear twice.
public enum MeetingEchoDetector {
  /// Mic segments whose words are mostly (≥ 70%) covered by runs of three or more words from
  /// Mac-audio segments within ±3 seconds are marked as echo. Nothing is deleted.
  public static let minimumCoverage = 0.7
  public static let window: TimeInterval = 3
  static let runLength = 3

  public static func marking(_ transcript: [MeetingTranscriptSegment])
    -> [MeetingTranscriptSegment]
  {
    let system = transcript.filter { $0.source == .system && !$0.isFailed && !$0.text.isEmpty }
      .sorted { $0.offset < $1.offset }
    return transcript.map { segment in
      guard segment.source == .microphone, !segment.isFailed else { return segment }
      let nearby = system.filter {
        $0.offset <= segment.offset + segment.duration + window
          && $0.offset + $0.duration >= segment.offset - window
      }
      var marked = segment
      let echo = !nearby.isEmpty && isEcho(segment.text, of: nearby.map(\.text))
      marked.echoOfSystemAudio = echo ? true : nil
      return marked
    }
  }

  static func isEcho(_ microphone: String, of system: [String]) -> Bool {
    let words = normalizedWords(microphone)
    guard words.count >= runLength else { return false }
    var grams = Set<[String]>()
    for text in system {
      let other = normalizedWords(text)
      guard other.count >= runLength else { continue }
      for start in 0...(other.count - runLength) {
        grams.insert(Array(other[start..<(start + runLength)]))
      }
    }
    guard !grams.isEmpty else { return false }
    var covered = [Bool](repeating: false, count: words.count)
    for start in 0...(words.count - runLength)
    where grams.contains(Array(words[start..<(start + runLength)])) {
      for index in start..<(start + runLength) { covered[index] = true }
    }
    return Double(covered.filter { $0 }.count) / Double(words.count) >= minimumCoverage
  }

  static func normalizedWords(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " "
      }
      .split(separator: " ").map { String($0).replacingOccurrences(of: "'", with: "") }
      .filter { !$0.isEmpty }
  }
}

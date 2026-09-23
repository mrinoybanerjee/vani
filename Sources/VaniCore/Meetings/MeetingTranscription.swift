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

/// Text-based, conservative speaker-echo detection. Without headphones the microphone hears
/// remote speech that ScreenCaptureKit also captures as Mac audio, so the same words appear twice.
///
/// A microphone segment is echo only when it is long and almost entirely repeats Mac audio that
/// was playing at the same time: at least 8 words, at least 90% of them and all but at most 2
/// covered by runs of three or more words from Mac-audio segments whose time span overlaps its
/// own. A short reply that repeats a question, or a chunk mixing the user's own words with echo,
/// stays visible and summarizable. Nothing is deleted. Normalized words are cached per segment,
/// and adding a segment re-evaluates only the microphone segments whose time span it touches.
public struct MeetingEchoDetector: Sendable {
  public static let minimumWords = 8
  public static let minimumCoverage = 0.9
  public static let maximumUncoveredWords = 2
  /// Capture latency between the two sources, not a search window over neighbouring chunks.
  public static let alignmentSlack: TimeInterval = 0.5
  static let runLength = 3

  private var words: [UUID: [String]] = [:]

  public init() {}

  /// Appends `segment` and returns the transcript with echo flags updated where it matters.
  /// Work is proportional to the segments overlapping `segment`, plus one offset scan.
  public mutating func adding(
    _ segment: MeetingTranscriptSegment, to transcript: [MeetingTranscriptSegment]
  ) -> [MeetingTranscriptSegment] {
    var result = transcript
    result.append(segment)
    let affected = result.indices.filter {
      result[$0].source == .microphone && !result[$0].isFailed
        && (result[$0].id == segment.id
          || (segment.source == .system && Self.overlaps(result[$0], segment)))
    }
    guard !affected.isEmpty else { return result }
    for index in affected {
      let microphone = result[index]
      let aligned = result.filter {
        $0.source == .system && !$0.isFailed && !$0.text.isEmpty
          && Self.overlaps(microphone, $0)
      }
      result[index].echoOfSystemAudio = isEcho(microphone, of: aligned) ? true : nil
    }
    return result
  }

  static func overlaps(_ first: MeetingTranscriptSegment, _ second: MeetingTranscriptSegment)
    -> Bool
  {
    first.offset < second.offset + second.duration + alignmentSlack
      && second.offset < first.offset + first.duration + alignmentSlack
  }

  private mutating func tokens(_ segment: MeetingTranscriptSegment) -> [String] {
    if let cached = words[segment.id] { return cached }
    let normalized = Self.normalizedWords(segment.text)
    words[segment.id] = normalized
    return normalized
  }

  private mutating func isEcho(
    _ microphone: MeetingTranscriptSegment, of system: [MeetingTranscriptSegment]
  ) -> Bool {
    let spoken = tokens(microphone)
    guard spoken.count >= Self.minimumWords, !system.isEmpty else { return false }
    var grams = Set<[String]>()
    for segment in system {
      let other = tokens(segment)
      guard other.count >= Self.runLength else { continue }
      for start in 0...(other.count - Self.runLength) {
        grams.insert(Array(other[start..<(start + Self.runLength)]))
      }
    }
    guard !grams.isEmpty else { return false }
    var covered = [Bool](repeating: false, count: spoken.count)
    for start in 0...(spoken.count - Self.runLength)
    where grams.contains(Array(spoken[start..<(start + Self.runLength)])) {
      for index in start..<(start + Self.runLength) { covered[index] = true }
    }
    let coveredCount = covered.filter { $0 }.count
    return spoken.count - coveredCount <= Self.maximumUncoveredWords
      && Double(coveredCount) / Double(spoken.count) >= Self.minimumCoverage
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

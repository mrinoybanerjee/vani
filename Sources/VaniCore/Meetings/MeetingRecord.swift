import Foundation

public enum MeetingAudioSource: String, Codable, Sendable {
  case microphone
  case system
  /// Sources are capture devices, not identified people: "Me" is this Mac's microphone and
  /// "Others" is the other audio playing on the Mac.
  public var label: String { self == .microphone ? "Me" : "Others" }
}

/// Bounds for one meeting, shared by capture, storage validation and summaries.
///
/// Four hours covers long workshops, interviews and planning sessions while keeping every
/// dependent cost bounded: raw audio (about 1.7 GiB when both sources are active throughout),
/// the transcript record, echo marking, the transcript view and local summary time. A hard
/// bound also stops a forgotten meeting from recording indefinitely. Every limit that depends
/// on duration scales from `maximumDuration`; records written under the earlier two-hour
/// limits remain valid.
public enum MeetingLimits {
  public static let maximumDuration: TimeInterval = 4 * 60 * 60
  /// Chunks normally last 15–24 seconds per source. Delivery gaps, sample-rate changes and
  /// Mac audio that stops during silence end chunks early, so the bound allows an average of
  /// one chunk every 10 seconds from each source (1,440 per source over four hours).
  public static let maximumSegments = 2 * Int(maximumDuration / 10)
  /// A four-hour record measured about 0.5 MiB; the bound leaves room for dense speech and
  /// 1 MiB each of notes and summary.
  public static let maximumRecordBytes = 16 * 1_024 * 1_024
  /// Saved audio: 16 kHz mono Float32 from each of the two sources.
  public static let audioBytesPerSecond = 2 * CapturedAudio.targetSampleRate * 4
}

/// `m:ss` for transcript offsets that the store has already validated as finite and bounded.
public func meetingTimestamp(_ seconds: TimeInterval) -> String {
  let whole = Int(max(0, seconds))
  return "\(whole / 60):\(String(format: "%02d", whole % 60))"
}

public struct MeetingTranscriptSegment: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public let source: MeetingAudioSource
  public let offset: TimeInterval
  public let duration: TimeInterval
  public let text: String
  /// Microphone text that repeats nearby Mac audio (speaker echo). Hidden by default, never deleted.
  public var echoOfSystemAudio: Bool?
  /// Transcription failed repeatedly. The chunk's audio is kept so it can be retried later.
  public let failed: Bool?

  public init(
    id: UUID, source: MeetingAudioSource, offset: TimeInterval, duration: TimeInterval,
    text: String, echoOfSystemAudio: Bool? = nil, failed: Bool? = nil
  ) {
    self.id = id
    self.source = source
    self.offset = offset
    self.duration = duration
    self.text = text
    self.echoOfSystemAudio = echoOfSystemAudio
    self.failed = failed
  }

  public var isEcho: Bool { echoOfSystemAudio == true }
  public var isFailed: Bool { failed == true }
  /// Real transcribed speech: not an echo, not a failure placeholder and not silence.
  public var isSpeech: Bool {
    !isEcho && !isFailed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  public var timeRange: String {
    "\(meetingTimestamp(offset))–\(meetingTimestamp(offset + duration))"
  }
}

public struct MeetingRecord: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var title: String
  public var createdAt: Date
  public var endedAt: Date?
  public var notes: String
  public var transcript: [MeetingTranscriptSegment]
  public var summary: String
  public var deletedAt: Date?

  public init(id: UUID = UUID(), title: String = "Untitled meeting", createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    notes = ""
    transcript = []
    summary = ""
  }

  /// Speech and failure placeholders in time order. Echo copies are omitted from exports.
  private var exportedSegments: [MeetingTranscriptSegment] {
    transcript.filter { $0.isSpeech || $0.isFailed }.sorted { $0.offset < $1.offset }
  }

  public var exportedText: String {
    let lines = exportedSegments.map {
      $0.isFailed
        ? "[\(meetingTimestamp($0.offset)) · \($0.source.label)] (Couldn’t transcribe \($0.timeRange))"
        : "[\(meetingTimestamp($0.offset)) · \($0.source.label)] \($0.text)"
    }.joined(separator: "\n\n")
    return "\(title)\n\nMY NOTES\n\(notes)\n\nSUMMARY\n\(summary)\n\nTRANSCRIPT\n\(lines)"
  }

  public var markdownText: String {
    func section(_ heading: String, _ body: String) -> String {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "## \(heading)\n\n\(trimmed.isEmpty ? "_None_" : trimmed)"
    }
    let transcript = exportedSegments.map {
      $0.isFailed
        ? "**\($0.source.label) · \(meetingTimestamp($0.offset))** _Couldn’t transcribe \($0.timeRange)_"
        : "**\($0.source.label) · \(meetingTimestamp($0.offset))** \($0.text)"
    }.joined(separator: "\n\n")
    let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      "# \(heading.isEmpty ? "Untitled meeting" : heading)", section("My notes", notes),
      section("Summary", summary), section("Transcript", transcript),
    ].joined(separator: "\n\n") + "\n"
  }

  /// A file name derived from the title without path separators or hidden-file prefixes.
  public var exportFileName: String {
    let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
      .union(.newlines)
    let cleaned = title.unicodeScalars.map { unsafe.contains($0) ? "-" : String($0) }.joined()
      .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    return String((cleaned.isEmpty ? "Vani Meeting" : cleaned).prefix(120))
  }
}

public struct MeetingAudioChunk: Codable, Identifiable, Sendable {
  public let id: UUID
  public let source: MeetingAudioSource
  public let offset: TimeInterval
  public let sampleRate: Int
  public let pcm: Data

  public init(id: UUID = UUID(), source: MeetingAudioSource, offset: TimeInterval, samples: [Float])
  {
    self.id = id
    self.source = source
    self.offset = offset
    sampleRate = CapturedAudio.targetSampleRate
    pcm = samples.withUnsafeBytes { Data($0) }
  }

  /// What a chunk's file name says about it. New names carry the source and offset, so pending
  /// audio can be ordered, and an unreadable chunk reported, without decoding the audio.
  /// Older names are the bare chunk ID.
  public struct Identity: Sendable, Equatable {
    public let id: UUID
    public let source: MeetingAudioSource?
    public let offset: TimeInterval?
  }

  public static let fileExtension = "vani-audio"

  /// `<UUID>_<mic|sys>_<offset in milliseconds>.vani-audio`
  public var fileName: String {
    "\(id.uuidString)_\(source == .microphone ? "mic" : "sys")_\(Int((offset * 1000).rounded()))."
      + Self.fileExtension
  }

  public static func identity(fromFileName name: String) -> Identity? {
    guard name.hasSuffix("." + fileExtension) else { return nil }
    let parts = name.dropLast(fileExtension.count + 1).split(
      separator: "_", omittingEmptySubsequences: false)
    guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
    if parts.count == 1 { return Identity(id: id, source: nil, offset: nil) }
    guard parts.count == 3, let milliseconds = Int(parts[2]),
      (0...Int(MeetingLimits.maximumDuration * 1000)).contains(milliseconds)
    else { return nil }
    let source: MeetingAudioSource
    switch parts[1] {
    case "mic": source = .microphone
    case "sys": source = .system
    default: return nil
    }
    return Identity(id: id, source: source, offset: Double(milliseconds) / 1000)
  }

  public func audio() throws -> CapturedAudio {
    guard sampleRate == CapturedAudio.targetSampleRate, pcm.count % 4 == 0,
      pcm.count <= 4 * sampleRate * 25, offset.isFinite, offset >= 0,
      offset <= MeetingLimits.maximumDuration
    else {
      throw MeetingError.invalidData
    }
    var samples = [Float](repeating: 0, count: pcm.count / 4)
    _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
    guard samples.allSatisfy(\.isFinite) else { throw MeetingError.invalidData }
    return CapturedAudio(samples: samples)
  }
}

public enum MeetingError: Error, LocalizedError, Sendable {
  case invalidData
  case storage(String)
  case capture(String)
  case summary(String)

  public var errorDescription: String? {
    switch self {
    case .invalidData:
      "The meeting file could not be read safely. Your existing files have been preserved."
    case .storage(let detail), .capture(let detail), .summary(let detail): detail
    }
  }
}

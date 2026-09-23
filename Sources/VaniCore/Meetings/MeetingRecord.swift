import Foundation

public enum MeetingAudioSource: String, Codable, Sendable {
  case microphone
  case system
  /// Sources are capture devices, not identified people: "Me" is this Mac's microphone and
  /// "Others" is the other audio playing on the Mac.
  public var label: String { self == .microphone ? "Me" : "Others" }
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

  public func audio() throws -> CapturedAudio {
    guard sampleRate == CapturedAudio.targetSampleRate, pcm.count % 4 == 0,
      pcm.count <= 4 * sampleRate * 25, offset.isFinite, offset >= 0, offset <= 7200
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

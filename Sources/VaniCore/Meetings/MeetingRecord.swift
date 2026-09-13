import Foundation

public enum MeetingAudioSource: String, Codable, Sendable {
  case microphone
  case system
  public var label: String { self == .microphone ? "Microphone" : "Meeting audio" }
}

public struct MeetingTranscriptSegment: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public let source: MeetingAudioSource
  public let offset: TimeInterval
  public let duration: TimeInterval
  public let text: String

  public init(
    id: UUID, source: MeetingAudioSource, offset: TimeInterval, duration: TimeInterval, text: String
  ) {
    self.id = id
    self.source = source
    self.offset = offset
    self.duration = duration
    self.text = text
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

  public var exportedText: String {
    let lines = transcript.sorted { $0.offset < $1.offset }.map {
      "[\(Int($0.offset) / 60):\(String(format: "%02d", Int($0.offset) % 60)) · \($0.source.label)] \($0.text)"
    }.joined(separator: "\n\n")
    return "\(title)\n\nMY NOTES\n\(notes)\n\nSUMMARY\n\(summary)\n\nTRANSCRIPT\n\(lines)"
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

import Foundation

public enum DiagnosticCategory: String, Codable, Sendable, Equatable {
  case lifecycle
  case permission
  case capture
  case model
  case transcription
  case insertion
  case recovery
  case storage
}

public struct DiagnosticEvent: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let timestamp: Date
  public let category: DiagnosticCategory
  public let code: String
  public let phase: SessionPhase?
  public let durationMilliseconds: Int?

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    category: DiagnosticCategory,
    code: String,
    phase: SessionPhase? = nil,
    durationMilliseconds: Int? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.category = category
    self.code = code
    self.phase = phase
    self.durationMilliseconds = durationMilliseconds
  }
}

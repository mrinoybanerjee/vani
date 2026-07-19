import Foundation

public struct BenchmarkResult: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let recordedAt: Date
  public let commit: String
  public let hardware: String
  public let operatingSystem: String
  public let configuration: String
  public let model: String
  public let metrics: [String: Double]

  public init(
    recordedAt: Date = Date(),
    commit: String,
    hardware: String,
    operatingSystem: String,
    configuration: String,
    model: String,
    metrics: [String: Double]
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.recordedAt = recordedAt
    self.commit = commit
    self.hardware = hardware
    self.operatingSystem = operatingSystem
    self.configuration = configuration
    self.model = model
    self.metrics = metrics
  }
}

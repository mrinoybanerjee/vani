import Foundation

public struct SpeechResult: Sendable, Equatable {
  public let text: String
  public let confidence: Float
  public let audioDuration: TimeInterval
  public let processingDuration: TimeInterval

  public init(
    text: String,
    confidence: Float,
    audioDuration: TimeInterval,
    processingDuration: TimeInterval
  ) {
    self.text = text
    self.confidence = confidence
    self.audioDuration = audioDuration
    self.processingDuration = processingDuration
  }
}

public protocol SpeechRecognizing: Sendable {
  func modelsAreInstalled() async -> Bool
  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
  func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult
}

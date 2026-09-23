import Foundation

public struct SpeechResult: Sendable, Equatable {
  public let text: String
  public let rawText: String?
  public let confidence: Float
  public let audioDuration: TimeInterval
  public let processingDuration: TimeInterval
  public let acousticPersonalizationAttempted: Bool

  public init(
    text: String,
    rawText: String? = nil,
    confidence: Float,
    audioDuration: TimeInterval,
    processingDuration: TimeInterval,
    acousticPersonalizationAttempted: Bool = false
  ) {
    self.text = text
    self.rawText = rawText
    self.confidence = confidence
    self.audioDuration = audioDuration
    self.processingDuration = processingDuration
    self.acousticPersonalizationAttempted = acousticPersonalizationAttempted
  }
}

public struct SpeechRecognitionContext: Sendable, Equatable {
  public let personalizedTerms: [SpeechPersonalizationTerm]

  public init(personalizedTerms: [SpeechPersonalizationTerm] = []) {
    self.personalizedTerms = personalizedTerms
  }

  public static let empty = SpeechRecognitionContext()
}

public protocol SpeechRecognizing: Sendable {
  func modelsAreInstalled() async -> Bool
  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
  func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult
  func transcribe(
    _ audio: CapturedAudio,
    context: SpeechRecognitionContext
  ) async throws -> SpeechResult
  func personalizationModelsAreInstalled() async -> Bool
  func preparePersonalizationModels(
    progress: @escaping @Sendable (Double) -> Void
  ) async throws
}

extension SpeechRecognizing {
  public func transcribe(
    _ audio: CapturedAudio,
    context: SpeechRecognitionContext
  ) async throws -> SpeechResult {
    try await transcribe(audio)
  }

  public func personalizationModelsAreInstalled() async -> Bool { false }

  public func preparePersonalizationModels(
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(1)
  }
}

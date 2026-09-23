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

/// The local English speech models Vani can run.
public enum SpeechModel: String, Sendable, Equatable {
  /// NVIDIA Parakeet Unified EN 0.6B (int8 encoder). Default since v0.7.0.
  case parakeetUnified
  /// NVIDIA Parakeet TDT 0.6B v2, kept as a fallback for existing installations.
  case parakeetTDTv2

  public var downloadSizeDescription: String {
    switch self {
    case .parakeetUnified: "583\u{00A0}MiB"
    case .parakeetTDTv2: "443\u{00A0}MiB"
    }
  }
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
  /// Loads optional personalization models ahead of use. Never required for dictation.
  func prewarmPersonalization() async
  /// The model transcriptions currently use, or nil before preparation.
  func activeModel() async -> SpeechModel?
  /// True when the preferred model is installed and verified.
  func preferredModelIsInstalled() async -> Bool
  /// Downloads (after an explicit user action) and switches to the preferred model.
  func installPreferredModel(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension SpeechRecognizing {
  public func transcribe(
    _ audio: CapturedAudio,
    context: SpeechRecognitionContext
  ) async throws -> SpeechResult {
    try await transcribe(audio)
  }

  public func personalizationModelsAreInstalled() async -> Bool { false }

  public func prewarmPersonalization() async {}

  public func activeModel() async -> SpeechModel? { nil }

  public func preferredModelIsInstalled() async -> Bool { await modelsAreInstalled() }

  public func installPreferredModel(progress: @escaping @Sendable (Double) -> Void) async throws {
    try await prepare(progress: progress)
  }

  public func preparePersonalizationModels(
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(1)
  }
}

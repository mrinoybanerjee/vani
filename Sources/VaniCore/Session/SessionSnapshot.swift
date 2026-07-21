import Foundation

public enum InsertionFeedback: Sendable, Equatable {
  case verified
  case unconfirmed
}

public struct SessionSnapshot: Sendable, Equatable {
  public let phase: SessionPhase
  public let failure: VaniFailure?
  public let modelProgress: Double?
  public let isModelReady: Bool
  public let hasRecoverableTranscript: Bool
  public let recoverableTranscript: String?
  public let insertionFeedback: InsertionFeedback?

  public init(
    phase: SessionPhase,
    failure: VaniFailure? = nil,
    modelProgress: Double? = nil,
    isModelReady: Bool = false,
    hasRecoverableTranscript: Bool = false,
    recoverableTranscript: String? = nil,
    insertionFeedback: InsertionFeedback? = nil
  ) {
    self.phase = phase
    self.failure = failure
    self.modelProgress = modelProgress
    self.isModelReady = isModelReady
    self.hasRecoverableTranscript = hasRecoverableTranscript
    self.recoverableTranscript = recoverableTranscript
    self.insertionFeedback = insertionFeedback
  }

  public static let initial = SessionSnapshot(phase: .setup)
}

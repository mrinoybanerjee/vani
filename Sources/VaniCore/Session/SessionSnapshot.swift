public enum InsertionFeedback: Sendable, Equatable {
  case verified
  case verifiedCaptureTruncated
  case unconfirmed
}

public struct SessionSnapshot: Sendable, Equatable {
  public let phase: SessionPhase
  public let failure: VaniFailure?
  public let modelProgress: Double?
  public let isModelReady: Bool
  public let hasLastTranscript: Bool
  public let hasRecoverableTranscript: Bool
  public let recoverableTranscript: String?
  public let insertionFeedback: InsertionFeedback?
  public let isRecordingLimitApproaching: Bool

  public init(
    phase: SessionPhase,
    failure: VaniFailure? = nil,
    modelProgress: Double? = nil,
    isModelReady: Bool = false,
    hasLastTranscript: Bool = false,
    hasRecoverableTranscript: Bool = false,
    recoverableTranscript: String? = nil,
    insertionFeedback: InsertionFeedback? = nil,
    isRecordingLimitApproaching: Bool = false
  ) {
    self.phase = phase
    self.failure = failure
    self.modelProgress = modelProgress
    self.isModelReady = isModelReady
    self.hasLastTranscript = hasLastTranscript
    self.hasRecoverableTranscript = hasRecoverableTranscript
    self.recoverableTranscript = recoverableTranscript
    self.insertionFeedback = insertionFeedback
    self.isRecordingLimitApproaching = isRecordingLimitApproaching
  }

  public static let initial = SessionSnapshot(phase: .setup)
}

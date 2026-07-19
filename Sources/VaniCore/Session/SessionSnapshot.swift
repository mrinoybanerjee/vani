import Foundation

public struct SessionSnapshot: Sendable, Equatable {
  public let phase: SessionPhase
  public let failure: VaniFailure?
  public let modelProgress: Double?
  public let isModelReady: Bool
  public let hasRecoverableTranscript: Bool
  public let recoverableTranscript: String?

  public init(
    phase: SessionPhase,
    failure: VaniFailure? = nil,
    modelProgress: Double? = nil,
    isModelReady: Bool = false,
    hasRecoverableTranscript: Bool = false,
    recoverableTranscript: String? = nil
  ) {
    self.phase = phase
    self.failure = failure
    self.modelProgress = modelProgress
    self.isModelReady = isModelReady
    self.hasRecoverableTranscript = hasRecoverableTranscript
    self.recoverableTranscript = recoverableTranscript
  }

  public static let initial = SessionSnapshot(phase: .setup)
}

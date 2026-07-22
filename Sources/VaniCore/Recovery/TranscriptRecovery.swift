import Foundation

public enum RecoveryStage: String, Codable, Sendable, Equatable {
  case transcription
  case insertion
}

public struct RecoveryPayload: Sendable, Equatable {
  public var audio: CapturedAudio?
  public var transcript: String?
  public var target: TextTarget?
  public var stage: RecoveryStage
  public var shouldAppendToHistory: Bool

  public init(
    audio: CapturedAudio? = nil,
    transcript: String? = nil,
    target: TextTarget? = nil,
    stage: RecoveryStage,
    shouldAppendToHistory: Bool = true
  ) {
    self.audio = audio
    self.transcript = transcript
    self.target = target
    self.stage = stage
    self.shouldAppendToHistory = shouldAppendToHistory
  }
}

public actor TranscriptRecovery {
  private var payload: RecoveryPayload?

  public init() {}

  public func retainAudio(_ audio: CapturedAudio, target: TextTarget?) {
    payload = RecoveryPayload(audio: audio, target: target, stage: .transcription)
  }

  public func retainTranscript(
    _ transcript: String,
    target: TextTarget?,
    shouldAppendToHistory: Bool = true
  ) {
    if payload == nil {
      payload = RecoveryPayload(target: target, stage: .insertion)
    }
    payload?.transcript = transcript
    payload?.target = target
    payload?.stage = .insertion
    payload?.shouldAppendToHistory = shouldAppendToHistory
  }

  public func latest() -> RecoveryPayload? {
    payload
  }

  public func clear() {
    payload = nil
  }
}

import Foundation

public enum SessionPhase: String, Codable, CaseIterable, Sendable, Equatable {
  case setup
  case preparing
  case ready
  case listening
  case transcribing
  case inserting
  case recoverableError
  case disabled
}

public enum SessionEvent: String, Codable, CaseIterable, Sendable, Equatable {
  case prepare
  case preparationSucceeded
  case captureStarted
  case captureStopped
  case transcriptReady
  case pasteLastRequested
  case insertionSucceeded
  case failed
  case retryPreparation
  case retryTranscription
  case retryInsertion
  case dismissToSetup
  case dismissToReady
  case permissionsLost
  case audioRouteChanged
  case systemWillSleep
  case resume
  case terminate
}

public struct InvalidSessionTransition: Error, Sendable, Equatable {
  public let phase: SessionPhase
  public let event: SessionEvent

  public init(phase: SessionPhase, event: SessionEvent) {
    self.phase = phase
    self.event = event
  }
}

public struct SessionStateMachine: Sendable, Equatable {
  public private(set) var phase: SessionPhase

  public init(phase: SessionPhase = .setup) {
    self.phase = phase
  }

  @discardableResult
  public mutating func transition(_ event: SessionEvent) throws -> SessionPhase {
    guard let destination = Self.destination(from: phase, event: event) else {
      throw InvalidSessionTransition(phase: phase, event: event)
    }
    phase = destination
    return destination
  }

  public static func destination(
    from phase: SessionPhase,
    event: SessionEvent
  ) -> SessionPhase? {
    switch (phase, event) {
    case (.setup, .prepare): .preparing
    case (.setup, .permissionsLost): .setup
    case (.setup, .terminate): .disabled

    case (.preparing, .preparationSucceeded): .ready
    case (.preparing, .failed): .recoverableError
    case (.preparing, .permissionsLost): .setup
    case (.preparing, .audioRouteChanged), (.preparing, .systemWillSleep): .preparing
    case (.preparing, .terminate): .disabled

    case (.ready, .prepare): .preparing
    case (.ready, .captureStarted): .listening
    case (.ready, .pasteLastRequested): .inserting
    case (.ready, .failed): .recoverableError
    case (.ready, .permissionsLost): .setup
    case (.ready, .audioRouteChanged), (.ready, .systemWillSleep): .preparing
    case (.ready, .terminate): .disabled

    case (.listening, .captureStopped): .transcribing
    case (.listening, .failed), (.listening, .permissionsLost),
      (.listening, .audioRouteChanged), (.listening, .systemWillSleep):
      .recoverableError
    case (.listening, .terminate): .disabled

    case (.transcribing, .transcriptReady): .inserting
    case (.transcribing, .failed): .recoverableError
    case (.transcribing, .terminate): .disabled

    case (.inserting, .insertionSucceeded): .ready
    case (.inserting, .failed): .recoverableError
    case (.inserting, .terminate): .disabled

    case (.recoverableError, .retryPreparation): .preparing
    case (.recoverableError, .retryTranscription): .transcribing
    case (.recoverableError, .retryInsertion): .inserting
    case (.recoverableError, .dismissToSetup): .setup
    case (.recoverableError, .dismissToReady): .ready
    case (.recoverableError, .permissionsLost): .setup
    case (.recoverableError, .terminate): .disabled

    case (.disabled, .resume): .setup
    case (.disabled, .terminate): .disabled

    default: nil
    }
  }
}

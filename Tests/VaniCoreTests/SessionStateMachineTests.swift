import Testing

@testable import VaniCore

private struct TransitionKey: Hashable {
  let phase: SessionPhase
  let event: SessionEvent
}

@Test
func happyPathTransitions() throws {
  var machine = SessionStateMachine()

  #expect(try machine.transition(.prepare) == .preparing)
  #expect(try machine.transition(.preparationSucceeded) == .ready)
  #expect(try machine.transition(.captureStarted) == .listening)
  #expect(try machine.transition(.captureStopped) == .transcribing)
  #expect(try machine.transition(.transcriptReady) == .inserting)
  #expect(try machine.transition(.insertionSucceeded) == .ready)
}

@Test
func everyPhaseEventPairMatchesTheApprovedTransitionTable() throws {
  let expected: [TransitionKey: SessionPhase] = [
    .init(phase: .setup, event: .prepare): .preparing,
    .init(phase: .setup, event: .permissionsLost): .setup,
    .init(phase: .setup, event: .terminate): .disabled,

    .init(phase: .preparing, event: .preparationSucceeded): .ready,
    .init(phase: .preparing, event: .failed): .recoverableError,
    .init(phase: .preparing, event: .permissionsLost): .setup,
    .init(phase: .preparing, event: .audioRouteChanged): .preparing,
    .init(phase: .preparing, event: .systemWillSleep): .preparing,
    .init(phase: .preparing, event: .terminate): .disabled,

    .init(phase: .ready, event: .prepare): .preparing,
    .init(phase: .ready, event: .captureStarted): .listening,
    .init(phase: .ready, event: .failed): .recoverableError,
    .init(phase: .ready, event: .permissionsLost): .setup,
    .init(phase: .ready, event: .audioRouteChanged): .preparing,
    .init(phase: .ready, event: .systemWillSleep): .preparing,
    .init(phase: .ready, event: .terminate): .disabled,

    .init(phase: .listening, event: .captureStopped): .transcribing,
    .init(phase: .listening, event: .failed): .recoverableError,
    .init(phase: .listening, event: .permissionsLost): .recoverableError,
    .init(phase: .listening, event: .audioRouteChanged): .recoverableError,
    .init(phase: .listening, event: .systemWillSleep): .recoverableError,
    .init(phase: .listening, event: .terminate): .disabled,

    .init(phase: .transcribing, event: .transcriptReady): .inserting,
    .init(phase: .transcribing, event: .failed): .recoverableError,
    .init(phase: .transcribing, event: .terminate): .disabled,

    .init(phase: .inserting, event: .insertionSucceeded): .ready,
    .init(phase: .inserting, event: .failed): .recoverableError,
    .init(phase: .inserting, event: .terminate): .disabled,

    .init(phase: .recoverableError, event: .retryPreparation): .preparing,
    .init(phase: .recoverableError, event: .retryTranscription): .transcribing,
    .init(phase: .recoverableError, event: .retryInsertion): .inserting,
    .init(phase: .recoverableError, event: .dismissToSetup): .setup,
    .init(phase: .recoverableError, event: .dismissToReady): .ready,
    .init(phase: .recoverableError, event: .permissionsLost): .setup,
    .init(phase: .recoverableError, event: .terminate): .disabled,

    .init(phase: .disabled, event: .resume): .setup,
    .init(phase: .disabled, event: .terminate): .disabled,
  ]

  for phase in SessionPhase.allCases {
    for event in SessionEvent.allCases {
      let key = TransitionKey(phase: phase, event: event)
      var machine = SessionStateMachine(phase: phase)

      if let destination = expected[key] {
        #expect(try machine.transition(event) == destination)
      } else {
        #expect(throws: InvalidSessionTransition.self) {
          try machine.transition(event)
        }
      }
    }
  }
}

@Test
func duplicateCaptureEventsAreRejected() throws {
  var machine = SessionStateMachine(phase: .ready)
  try machine.transition(.captureStarted)

  #expect(throws: InvalidSessionTransition.self) {
    try machine.transition(.captureStarted)
  }

  try machine.transition(.captureStopped)
  #expect(throws: InvalidSessionTransition.self) {
    try machine.transition(.captureStopped)
  }
}

@Test
func failuresRemainRecoverableAtEveryOperationalStage() throws {
  for phase in [
    SessionPhase.preparing,
    .ready,
    .listening,
    .transcribing,
    .inserting,
  ] {
    var machine = SessionStateMachine(phase: phase)
    #expect(try machine.transition(.failed) == .recoverableError)
  }
}

@Test
func recoveryRoutesAreExplicit() throws {
  var preparation = SessionStateMachine(phase: .recoverableError)
  #expect(try preparation.transition(.retryPreparation) == .preparing)

  var transcription = SessionStateMachine(phase: .recoverableError)
  #expect(try transcription.transition(.retryTranscription) == .transcribing)

  var insertion = SessionStateMachine(phase: .recoverableError)
  #expect(try insertion.transition(.retryInsertion) == .inserting)

  var setup = SessionStateMachine(phase: .recoverableError)
  #expect(try setup.transition(.dismissToSetup) == .setup)

  var ready = SessionStateMachine(phase: .recoverableError)
  #expect(try ready.transition(.dismissToReady) == .ready)

  #expect(VaniFailure.insertionFailed.recoveryAction == .retryInsertion)
  #expect(VaniFailure.insertionUnverified.recoveryAction == .copyTranscript)
  #expect(VaniFailure.focusChanged.recoveryAction == .copyTranscript)
  #expect(VaniFailure.clipboardChanged.recoveryAction == .copyTranscript)
  #expect(
    VaniFailure.inputMonitoringPermissionDenied.recoveryAction
      == .openInputMonitoringSettings
  )
  #expect(VaniFailure.noSpeechDetected.title == "No speech recorded")
  #expect(VaniFailure.noSpeechDetected.dismissesAutomatically)
  #expect(VaniFailure.recordingTooShort.dismissesAutomatically)
  #expect(!VaniFailure.insertionUnverified.dismissesAutomatically)
}

@Test
func terminationIsIdempotent() throws {
  var machine = SessionStateMachine(phase: .ready)
  #expect(try machine.transition(.terminate) == .disabled)
  #expect(try machine.transition(.terminate) == .disabled)
  #expect(try machine.transition(.resume) == .setup)
}

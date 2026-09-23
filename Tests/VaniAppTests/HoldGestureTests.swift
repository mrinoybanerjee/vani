import Testing

@testable import Vani

private let start = ContinuousClock().now

@Test func holdingPastTheQuickTapThresholdFinishesOnRelease() {
  var gesture = HoldGesture()
  #expect(gesture.press(at: start, recordingInProgress: false) == .beginRecording)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(900)), handsFreeEnabled: true,
      recordingInProgress: true) == .finishRecording)
  #expect(gesture.state == .idle)
}

@Test func doubleTapLocksAndTheNextPressFinishes() {
  var gesture = HoldGesture()
  #expect(gesture.press(at: start, recordingInProgress: false) == .beginRecording)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(120)), handsFreeEnabled: true,
      recordingInProgress: true) == .waitForSecondTap)
  #expect(
    gesture.press(at: start.advanced(by: .milliseconds(250)), recordingInProgress: true)
      == .lockHandsFree)
  #expect(gesture.isHandsFreeLocked)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(330)), handsFreeEnabled: true,
      recordingInProgress: true) == .none)
  #expect(gesture.isHandsFreeLocked)
  #expect(
    gesture.press(at: start.advanced(by: .seconds(30)), recordingInProgress: true)
      == .finishRecording)
  #expect(!gesture.isHandsFreeLocked)
  #expect(
    gesture.release(
      at: start.advanced(by: .seconds(31)), handsFreeEnabled: true, recordingInProgress: false)
      == .none)
  #expect(gesture.state == .idle)
}

@Test func aSingleQuickTapFinishesWhenTheSecondTapWindowCloses() {
  var gesture = HoldGesture()
  _ = gesture.press(at: start, recordingInProgress: false)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(100)), handsFreeEnabled: true,
      recordingInProgress: true) == .waitForSecondTap)
  #expect(gesture.secondTapWindowElapsed() == .finishRecording)
  #expect(gesture.secondTapWindowElapsed() == .none)
}

@Test func quickTapsFinishImmediatelyWhenHandsFreeIsOff() {
  var gesture = HoldGesture()
  _ = gesture.press(at: start, recordingInProgress: false)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(100)), handsFreeEnabled: false,
      recordingInProgress: true) == .finishRecording)
}

@Test func aSecondPressAfterTheRecordingEndedStartsFresh() {
  var gesture = HoldGesture()
  _ = gesture.press(at: start, recordingInProgress: false)
  _ = gesture.release(
    at: start.advanced(by: .milliseconds(100)), handsFreeEnabled: true,
    recordingInProgress: true)
  #expect(
    gesture.press(at: start.advanced(by: .milliseconds(200)), recordingInProgress: false)
      == .none)
  #expect(gesture.state == .idle)
}

@Test func quickTapWithoutARecordingDoesNotWaitForASecondTap() {
  var gesture = HoldGesture()
  _ = gesture.press(at: start, recordingInProgress: false)
  #expect(
    gesture.release(
      at: start.advanced(by: .milliseconds(100)), handsFreeEnabled: true,
      recordingInProgress: false) == .finishRecording)
}

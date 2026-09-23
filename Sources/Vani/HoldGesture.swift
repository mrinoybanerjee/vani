/// Interprets presses and releases of the hold shortcut: hold-to-talk, and a double-tap
/// that locks recording hands-free until the next press. Pure and clock-injected so every
/// transition is unit tested; the coordinator performs the resulting actions.
struct HoldGesture: Equatable {
  enum State: Equatable {
    case idle
    case holding(since: ContinuousClock.Instant)
    case awaitingSecondTap
    /// Locked on; the press that locked it has not been released yet.
    case lockedWhilePressed
    case locked
    /// The press that stopped a locked recording has not been released yet.
    case stoppingWhilePressed
  }

  enum Action: Equatable {
    case none
    case beginRecording
    case finishRecording
    /// Keep recording; finish unless a second press arrives within `secondTapWindow`.
    case waitForSecondTap
    case lockHandsFree
  }

  /// A press released sooner than this may be the first half of a double-tap.
  static let quickTapThreshold: Duration = .milliseconds(300)
  static let secondTapWindow: Duration = .milliseconds(300)

  private(set) var state: State = .idle

  var isHandsFreeLocked: Bool { state == .locked || state == .lockedWhilePressed }
  var isHolding: Bool {
    if case .holding = state { return true }
    return false
  }

  mutating func press(at now: ContinuousClock.Instant, recordingInProgress: Bool) -> Action {
    switch state {
    case .locked:
      state = .stoppingWhilePressed
      return .finishRecording
    case .awaitingSecondTap:
      guard recordingInProgress else {
        state = .idle
        return .none
      }
      state = .lockedWhilePressed
      return .lockHandsFree
    case .idle, .holding, .lockedWhilePressed, .stoppingWhilePressed:
      state = .holding(since: now)
      return .beginRecording
    }
  }

  mutating func release(
    at now: ContinuousClock.Instant, handsFreeEnabled: Bool, recordingInProgress: Bool
  ) -> Action {
    switch state {
    case .holding(let since):
      guard handsFreeEnabled, now - since < Self.quickTapThreshold, recordingInProgress else {
        state = .idle
        return .finishRecording
      }
      state = .awaitingSecondTap
      return .waitForSecondTap
    case .lockedWhilePressed:
      state = .locked
      return .none
    case .stoppingWhilePressed:
      state = .idle
      return .none
    case .idle, .awaitingSecondTap, .locked:
      return .finishRecording
    }
  }

  /// The second-tap window closed without another press.
  mutating func secondTapWindowElapsed() -> Action {
    guard state == .awaitingSecondTap else { return .none }
    state = .idle
    return .finishRecording
  }

  mutating func reset() { state = .idle }
}

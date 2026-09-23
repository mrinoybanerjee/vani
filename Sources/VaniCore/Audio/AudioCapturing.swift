public protocol AudioCapturing: Sendable {
  func start() async throws
  func stop() async throws -> CapturedAudio
  func recoverPendingAudio() async throws -> CapturedAudio?
  func cancel() async
  /// Continues an active recording on the current input after a route change. Returns
  /// false when capture cannot continue; audio captured so far remains available to `stop()`.
  func continueOnCurrentInput() async -> Bool
  /// The input route changed while idle.
  func inputRouteChanged() async
}

extension AudioCapturing {
  public func continueOnCurrentInput() async -> Bool { false }

  public func inputRouteChanged() async {}

  public func recoverPendingAudio() async throws -> CapturedAudio? {
    nil
  }
}

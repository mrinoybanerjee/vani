public protocol AudioCapturing: Sendable {
  /// RMS loudness of the most recent input, for display only.
  nonisolated var inputLevel: Float { get }
  func start() async throws
  func stop() async throws -> CapturedAudio
  func recoverPendingAudio() async throws -> CapturedAudio?
  func cancel() async
  /// Continues an active recording on the current input after a route change. Returns
  /// false when capture cannot continue; audio captured so far remains available to `stop()`.
  func continueOnCurrentInput() async -> Bool
  /// The input route changed while idle.
  func inputRouteChanged() async
  /// Reports capture that stopped on its own during a recording.
  func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) async
}

extension AudioCapturing {
  public nonisolated var inputLevel: Float { 0 }

  public func continueOnCurrentInput() async -> Bool { false }

  public func inputRouteChanged() async {}

  public func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) async {}

  public func recoverPendingAudio() async throws -> CapturedAudio? {
    nil
  }
}

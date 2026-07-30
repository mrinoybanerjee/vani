public protocol AudioCapturing: Sendable {
  func start() async throws
  func stop() async throws -> CapturedAudio
  func recoverPendingAudio() async throws -> CapturedAudio?
  func cancel() async
}

extension AudioCapturing {
  public func recoverPendingAudio() async throws -> CapturedAudio? {
    nil
  }
}

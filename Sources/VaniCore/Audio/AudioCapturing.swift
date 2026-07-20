import Foundation

public protocol AudioCapturing: Sendable {
  func start() async throws
  func stop() async throws -> CapturedAudio
  func cancel() async
}

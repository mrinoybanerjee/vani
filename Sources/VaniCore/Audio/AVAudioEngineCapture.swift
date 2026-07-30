import AVFoundation
import Foundation

public actor AVAudioEngineCapture: AudioCapturing {
  private let engine: AVAudioEngine
  private let ringBuffer: AudioSampleRingBuffer
  private let maximumDuration: TimeInterval
  private var isCapturing = false
  private var capacityTask: Task<Void, Never>?
  private var pendingSnapshot: AudioSampleRingBuffer.Snapshot?

  private static let initialCapacityDuration: TimeInterval = 3 * 60
  private static let capacityChunkDuration: TimeInterval = 60
  private static let capacityReservationInterval: Duration = .seconds(60)
  static let maximumSupportedInputSampleRate = 48_000.5

  public init(maximumDuration: TimeInterval = AudioPolicy.default.maximumDuration) {
    engine = AVAudioEngine()
    ringBuffer = AudioSampleRingBuffer()
    self.maximumDuration = maximumDuration
  }

  public func start() async throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw VaniFailure.microphonePermissionDenied
    }
    guard !isCapturing else { return }

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0 else {
      throw VaniFailure.audioDeviceUnavailable
    }
    try Self.validateInputSampleRate(format.sampleRate)

    let maximumFrames = max(1, Int(floor(format.sampleRate * maximumDuration)))
    let chunkFrames = min(
      maximumFrames,
      max(1_024, Int(ceil(format.sampleRate * Self.capacityChunkDuration)))
    )
    let initialFrames = min(
      maximumFrames,
      max(chunkFrames, Int(ceil(format.sampleRate * Self.initialCapacityDuration)))
    )
    let generation = ringBuffer.reset(
      capacity: initialFrames,
      maximumCapacity: maximumFrames,
      chunkCapacity: chunkFrames,
      sampleRate: format.sampleRate
    )

    input.installTap(onBus: 0, bufferSize: 1_024, format: format) {
      [ringBuffer] buffer, _ in
      ringBuffer.append(buffer)
    }

    do {
      engine.prepare()
      try engine.start()
      isCapturing = true
      startCapacityReservations(generation: generation)
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
      ringBuffer.clear()
      throw VaniFailure.audioCaptureFailed
    }
  }

  public func stop() async throws -> CapturedAudio {
    guard isCapturing else {
      throw VaniFailure.audioCaptureFailed
    }

    stopCapacityReservations()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isCapturing = false

    pendingSnapshot = ringBuffer.drain()
    guard let audio = try finalizePendingAudio() else {
      throw VaniFailure.audioFinalizationFailed
    }
    return audio
  }

  static func makeCapturedAudio(
    from snapshot: AudioSampleRingBuffer.Snapshot
  ) throws -> CapturedAudio {
    let converted = try SampleRateConverter.convert(
      snapshot.samples,
      from: snapshot.sampleRate
    )
    return CapturedAudio(
      samples: converted,
      wasTruncated: snapshot.overflowed
    )
  }

  static func validateInputSampleRate(_ sampleRate: Double) throws {
    guard sampleRate > 0 else {
      throw VaniFailure.audioDeviceUnavailable
    }
    guard sampleRate <= maximumSupportedInputSampleRate else {
      throw VaniFailure.unsupportedInputSampleRate
    }
  }

  public func cancel() async {
    stopCapacityReservations()
    if isCapturing {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      isCapturing = false
    }
    ringBuffer.clear()
    pendingSnapshot = nil
  }

  public func recoverPendingAudio() async throws -> CapturedAudio? {
    try finalizePendingAudio()
  }

  private func startCapacityReservations(generation: UInt64) {
    stopCapacityReservations()
    capacityTask = Task.detached(priority: .utility) { [ringBuffer] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.capacityReservationInterval)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        guard ringBuffer.reserveNextChunk(generation: generation) else { return }
      }
    }
  }

  private func stopCapacityReservations() {
    capacityTask?.cancel()
    capacityTask = nil
  }

  private func finalizePendingAudio() throws -> CapturedAudio? {
    guard let pendingSnapshot else { return nil }
    do {
      let audio = try Self.makeCapturedAudio(from: pendingSnapshot)
      self.pendingSnapshot = nil
      return audio
    } catch {
      throw VaniFailure.audioFinalizationFailed
    }
  }
}

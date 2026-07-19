import AVFoundation
import Foundation

public actor AVAudioEngineCapture: AudioCapturing {
  private let engine: AVAudioEngine
  private let ringBuffer: AudioSampleRingBuffer
  private let maximumDuration: TimeInterval
  private var isCapturing = false

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
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw VaniFailure.audioDeviceUnavailable
    }

    let maximumFrames = Int(ceil(format.sampleRate * maximumDuration))
    ringBuffer.reset(capacity: maximumFrames, sampleRate: format.sampleRate)

    input.installTap(onBus: 0, bufferSize: 1_024, format: format) {
      [ringBuffer] buffer, _ in
      ringBuffer.append(buffer)
    }

    do {
      engine.prepare()
      try engine.start()
      isCapturing = true
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
      throw VaniFailure.audioCaptureFailed
    }
  }

  public func stop() async throws -> CapturedAudio {
    guard isCapturing else {
      throw VaniFailure.audioCaptureFailed
    }

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isCapturing = false

    let snapshot = ringBuffer.snapshot()
    guard !snapshot.overflowed else {
      throw VaniFailure.recordingTooLong
    }

    let converted = try SampleRateConverter.convert(
      snapshot.samples,
      from: snapshot.sampleRate
    )
    return CapturedAudio(samples: converted)
  }

  public func cancel() async {
    if isCapturing {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      isCapturing = false
    }
  }
}

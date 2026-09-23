import AVFoundation
import CoreAudio
import Foundation

/// Records one dictation from the current input device. A recording is a sequence of
/// segments: when the input route changes (AirPods connect, a microphone is unplugged, the
/// default input changes), the current segment is kept and capture continues on the new
/// input. Segments keep their own sample rate and are converted and joined only when the
/// recording finishes, off the real-time thread.
public actor AVAudioEngineCapture: AudioCapturing {
  private var engine: AVAudioEngine
  private let ringBuffer: AudioSampleRingBuffer
  private let maximumDuration: TimeInterval
  /// A recording is in progress (possibly between segments after a failed continuation).
  private var isCapturing = false
  /// The engine is running and its tap feeds the ring buffer.
  private var engineRunning = false
  /// The input route changed while idle; the next recording starts on a fresh engine,
  /// which binds to the current default input.
  private var needsFreshEngine = false
  private var completedSegments: [AudioSampleRingBuffer.Snapshot] = []
  private var capacityTask: Task<Void, Never>?
  private var pendingSegments: [AudioSampleRingBuffer.Snapshot]?

  // Reserve a small first page so key-down does not allocate and zero-fill minutes of
  // audio; background reservations then stay at least 45 seconds ahead of capture.
  private static let initialCapacityDuration: TimeInterval = 60
  private static let capacityChunkDuration: TimeInterval = 30
  private static let capacityReservationInterval: Duration = .seconds(15)
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
    if needsFreshEngine {
      engine = AVAudioEngine()
      needsFreshEngine = false
    }
    completedSegments = []
    pendingSegments = nil
    try startSegment(maximumDuration: maximumDuration)
    isCapturing = true
  }

  /// Keeps an active recording going after an input route change. Returns false when no
  /// usable input remains; the audio captured so far is still returned by `stop()`.
  /// Synchronous inside the actor, so a concurrent stop cannot interleave with it.
  public func continueOnCurrentInput() async -> Bool {
    guard isCapturing else { return false }
    // Route changes often arrive in bursts; an engine still running on the current
    // default input needs nothing.
    if engineRunning, engine.isRunning,
      engine.inputNode.auAudioUnit.deviceID == Self.defaultInputDeviceID()
    {
      return true
    }
    closeSegment()
    engine = AVAudioEngine()
    let remaining = maximumDuration - capturedDuration
    guard remaining > 0.05 else { return false }
    do {
      try startSegment(maximumDuration: remaining)
      return true
    } catch {
      return false
    }
  }

  /// The input route changed while no recording is active.
  public func inputRouteChanged() async {
    if !isCapturing { needsFreshEngine = true }
  }

  public func stop() async throws -> CapturedAudio {
    guard isCapturing else {
      throw VaniFailure.audioCaptureFailed
    }
    closeSegment()
    isCapturing = false
    pendingSegments = completedSegments
    completedSegments = []
    guard let audio = try finalizePendingAudio() else {
      throw VaniFailure.audioFinalizationFailed
    }
    return audio
  }

  static func makeCapturedAudio(
    from snapshot: AudioSampleRingBuffer.Snapshot
  ) throws -> CapturedAudio {
    try makeCapturedAudio(from: [snapshot])
  }

  /// Converts each segment from its own sample rate and joins them in order.
  static func makeCapturedAudio(
    from segments: [AudioSampleRingBuffer.Snapshot]
  ) throws -> CapturedAudio {
    var samples: [Float] = []
    for segment in segments {
      samples += try SampleRateConverter.convert(segment.samples, from: segment.sampleRate)
    }
    return CapturedAudio(samples: samples, wasTruncated: segments.contains(where: \.overflowed))
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
    if engineRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engineRunning = false
    }
    isCapturing = false
    ringBuffer.clear()
    completedSegments = []
    pendingSegments = nil
  }

  public func recoverPendingAudio() async throws -> CapturedAudio? {
    try finalizePendingAudio()
  }

  /// The system default input device, or nil if none is available.
  static func defaultInputDeviceID() -> AudioDeviceID? {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
  }

  /// Seconds of audio in closed segments.
  private var capturedDuration: TimeInterval {
    completedSegments.reduce(0) { total, segment in
      segment.sampleRate > 0 ? total + Double(segment.samples.count) / segment.sampleRate : total
    }
  }

  private func startSegment(maximumDuration: TimeInterval) throws {
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
      engineRunning = true
      startCapacityReservations(generation: generation)
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
      ringBuffer.clear()
      throw VaniFailure.audioCaptureFailed
    }
  }

  /// Stops the engine and keeps the segment it captured.
  private func closeSegment() {
    stopCapacityReservations()
    guard engineRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engineRunning = false
    let segment = ringBuffer.drain()
    if !segment.samples.isEmpty || segment.overflowed {
      completedSegments.append(segment)
    }
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
    guard let pendingSegments else { return nil }
    do {
      let audio = try Self.makeCapturedAudio(from: pendingSegments)
      self.pendingSegments = nil
      return audio
    } catch {
      throw VaniFailure.audioFinalizationFailed
    }
  }
}

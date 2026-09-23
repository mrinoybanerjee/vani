import AVFoundation
import CoreAudio
import Foundation

/// Records one dictation. A recording is a sequence of segments: when the audio route
/// changes, the current segment is kept and capture resumes. It stays on the microphone the
/// take started with while that device is connected, because a newly selected input can take
/// seconds to deliver audio (measured: an iPhone Continuity microphone delivered nothing for
/// over 3 s after a switch). Only when that microphone disappears does capture move to the
/// current default input. Segments keep their own sample rate and are converted and joined
/// when the recording finishes, off the real-time thread.
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
  /// The input device of the current take, kept across route changes while it is connected.
  private var recordingDevice: AudioDeviceID?
  private var capacityTask: Task<Void, Never>?
  private var pendingSegments: [AudioSampleRingBuffer.Snapshot]?

  // Reserve a small first page so key-down does not allocate and zero-fill minutes of
  // audio; background reservations then stay at least 45 seconds ahead of capture.
  private static let initialCapacityDuration: TimeInterval = 60
  private static let capacityChunkDuration: TimeInterval = 30
  private static let capacityReservationInterval: Duration = .seconds(15)
  static let maximumSupportedInputSampleRate = 48_000.5

  /// Loudness of the latest audio callback, readable from any thread without waiting for the
  /// actor. Zero when not recording.
  public nonisolated var inputLevel: Float { ringBuffer.recentLevel }

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
    recordingDevice = nil
    try startSegment(maximumDuration: maximumDuration, device: Self.defaultInputDeviceID())
    recordingDevice = engine.inputNode.auAudioUnit.deviceID
    isCapturing = true
    deliveryRetries = 0
    scheduleDeliveryCheck()
  }

  /// Keeps an active recording going after an input route change. Returns false when no
  /// usable input remains; the audio captured so far is still returned by `stop()`.
  /// Synchronous inside the actor, so a concurrent stop cannot interleave with it.
  public func continueOnCurrentInput() async -> Bool {
    guard isCapturing else { return false }
    // The engine is bound to one device, so a default-input change leaves it recording.
    // Route changes also arrive in bursts; a healthy segment needs nothing.
    if engineRunning, engine.isRunning, let recordingDevice,
      Self.isConnectedInput(recordingDevice),
      engine.inputNode.auAudioUnit.deviceID == recordingDevice
    {
      return true
    }
    deliveryRetries = 0
    return restartSegment()
  }

  /// Closes the current segment and resumes on the take's microphone if it is still
  /// connected, otherwise on the current default input. A newly started engine is checked
  /// for delivered audio and restarted if it stays silent (observed right after a device
  /// is removed).
  private func restartSegment() -> Bool {
    closeSegment()
    engine = AVAudioEngine()
    let remaining = maximumDuration - capturedDuration
    guard remaining > 0.05 else { return false }
    let device =
      recordingDevice.flatMap { Self.isConnectedInput($0) ? $0 : nil }
      ?? Self.defaultInputDeviceID()
    do {
      try startSegment(maximumDuration: remaining, device: device)
      recordingDevice = engine.inputNode.auAudioUnit.deviceID
      scheduleDeliveryCheck()
      return true
    } catch {
      return false
    }
  }

  private var deliveryCheck: Task<Void, Never>?
  private var deliveryRetries = 0
  static let deliveryCheckDelay: Duration = .milliseconds(600)
  static let maximumDeliveryRetries = 3

  private func scheduleDeliveryCheck() {
    deliveryCheck?.cancel()
    let generation = segmentGeneration
    deliveryCheck = Task { [weak self] in
      try? await Task.sleep(for: Self.deliveryCheckDelay)
      guard !Task.isCancelled else { return }
      await self?.verifyDelivery(generation: generation)
    }
  }

  private func verifyDelivery(generation: UInt64) {
    guard isCapturing, engineRunning, generation == segmentGeneration else { return }
    guard ringBuffer.capturedCount == 0 else {
      deliveryRetries = 0
      return
    }
    guard deliveryRetries < Self.maximumDeliveryRetries else { return }
    deliveryRetries += 1
    VaniLog.event(category: .capture, code: "capture_segment_silent_restart")
    if !restartSegment() { interruptionHandler?() }
  }

  /// Called when capture ends on its own (no input could be resumed), so the session can
  /// keep what was recorded and tell the user.
  private var interruptionHandler: (@Sendable () -> Void)?

  public func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    interruptionHandler = handler
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
    deliveryRetries = 0
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
    deliveryCheck?.cancel()
    deliveryCheck = nil
    deliveryRetries = 0
    stopCapacityReservations()
    if engineRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engineRunning = false
    }
    isCapturing = false
    recordingDevice = nil
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

  /// True while the device is present and still offers input streams.
  static func isConnectedInput(_ device: AudioDeviceID) -> Bool {
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr, alive != 0
    else { return false }
    var streams = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var streamSize: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr
      && streamSize > 0
  }

  /// Seconds of audio in closed segments.
  private var capturedDuration: TimeInterval {
    completedSegments.reduce(0) { total, segment in
      segment.sampleRate > 0 ? total + Double(segment.samples.count) / segment.sampleRate : total
    }
  }

  private var segmentGeneration: UInt64 = 0

  private func startSegment(maximumDuration: TimeInterval, device: AudioDeviceID?) throws {
    segmentGeneration &+= 1
    let input = engine.inputNode
    // An explicit device stops the engine from following default-input changes, which
    // otherwise reconfigure it and silently end the tap's audio.
    if let device { try? input.auAudioUnit.setDeviceID(device) }
    // After re-binding, build the tap format from the bound hardware's rate and channels,
    // so a device with a different rate cannot trip AVAudioEngine's format assertion.
    let hardware = input.inputFormat(forBus: 0)
    guard hardware.sampleRate > 0, hardware.channelCount > 0,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
    else {
      throw VaniFailure.audioDeviceUnavailable
    }
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
    deliveryCheck?.cancel()
    deliveryCheck = nil
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

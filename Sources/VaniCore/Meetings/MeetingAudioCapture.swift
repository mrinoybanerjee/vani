import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
public protocol MeetingAudioRecording: AnyObject {
  var isCapturing: Bool { get }
  func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void) async throws
  func stop() async throws
  /// Non-fatal problems while capture continues, such as a microphone that did not return.
  func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void)
}

extension MeetingAudioRecording {
  public func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {}
}

/// ScreenCaptureKit supplies buffers on our serial work queue, not an audio render callback.
/// File writes and conversion stay off the main actor. No video output is registered or stored.
///
/// Capture heals itself. If the stream stops with an error it restarts up to three times.
/// If microphone audio stops arriving while the stream runs (ScreenCaptureKit raises no error
/// when the microphone is unplugged; measured on hardware) it restarts on the current default
/// input. A mere change of default input does not restart capture, which would also interrupt
/// Mac audio. The meeting timeline stays continuous; a short gap is recorded as a gap.
@available(macOS 15.0, *)
@MainActor
public final class MeetingAudioCapture: MeetingAudioRecording {
  private var captureStopped = false
  /// The current stream stopped with an error and has not been replaced yet.
  private var streamFailed = false
  public var isCapturing: Bool { stream != nil && !captureStopped && !streamFailed }
  private var stream: SCStream?
  private var output: MeetingStreamOutput?
  private var onFailure: (@Sendable (String) -> Void)?
  private var onWarning: (@Sendable (String) -> Void)?
  private var startedAt: ContinuousClock.Instant?
  /// Changes on every start and stop, so recovery work from an earlier meeting or an
  /// earlier stream can never act on the current one.
  private var captureGeneration: UInt64 = 0
  private var restarting = false
  private var stopping = false
  private var watchdog: Task<Void, Never>?
  private var silentMicrophoneRestarts = 0
  private var warnedAboutMicrophone = false
  /// Microphone buffers normally arrive every few milliseconds, silence included.
  static let microphoneSilenceLimit: TimeInterval = 2.5
  static let maximumSilentMicrophoneRestarts = 3
  private let queue = DispatchQueue(label: "com.mrinoy.vani.meeting-audio", qos: .userInitiated)
  static let restartAttempts = 3

  public init() {}

  public func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {
    onWarning = handler
  }

  public func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) async throws {
    guard stream == nil else { throw MeetingError.capture("A meeting is already recording.") }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw MeetingError.capture(
        "Allow Microphone access in System Settings before starting a meeting.")
    }
    captureGeneration &+= 1
    let output = MeetingStreamOutput(
      directory: directory, onChunk: onChunk, onFailure: onFailure,
      onStopped: { [weak self] identity, message in
        Task { @MainActor in await self?.streamStopped(identity, message) }
      })
    let stream = try await makeStream(output: output)
    self.output = output
    self.onFailure = onFailure
    self.stream = stream
    captureStopped = false
    streamFailed = false
    stopping = false
    warnedAboutMicrophone = false
    silentMicrophoneRestarts = 0
    startedAt = ContinuousClock().now
    do { try await launch(stream, output: output) } catch {
      self.stream = nil
      self.output = nil
      throw error
    }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await self?.checkMicrophone()
      }
    }
  }

  public func stop() async throws {
    guard let stream, let output else { return }
    stopping = true
    captureGeneration &+= 1
    watchdog?.cancel()
    watchdog = nil
    // A stream that already stopped with an error has nothing left to stop. Otherwise keep
    // both handles if stopping fails; callers must not claim the microphone is released.
    if !captureStopped, !streamFailed {
      try await stream.stopCapture()
    }
    captureStopped = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try output.finish()
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
    self.stream = nil
    self.output = nil
  }

  private func makeStream(output: MeetingStreamOutput) async throws -> SCStream {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw MeetingError.capture("No display is available for meeting audio capture.")
    }
    let excluded = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display, excludingApplications: excluded, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
    configuration.capturesAudio = true
    configuration.captureMicrophone = true  // The current default input.
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
    try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
    return stream
  }

  /// Registers the stream on the meeting timeline, then starts it. A stream that fails to
  /// start is forgotten, so it can never shadow the stream still recording.
  private func launch(_ stream: SCStream, output: MeetingStreamOutput) async throws {
    let identity = ObjectIdentifier(stream)
    let elapsed = elapsedTimeline
    queue.async { output.registerStream(identity, continuingAt: elapsed) }
    do {
      try await stream.startCapture()
    } catch {
      queue.async { output.forgetStream(identity) }
      throw error
    }
  }

  /// Seconds since the meeting started, used to place a restarted stream on the timeline.
  private var elapsedTimeline: TimeInterval {
    guard let startedAt else { return 0 }
    let elapsed = ContinuousClock().now - startedAt
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  /// The current stream stopped with an error. Restart it; give up only after repeated
  /// failures. Stops reported by already replaced streams are ignored.
  private func streamStopped(_ identity: ObjectIdentifier, _ message: String) async {
    guard let current = stream, ObjectIdentifier(current) == identity, !stopping else { return }
    streamFailed = true
    let generation = captureGeneration
    for attempt in 1...Self.restartAttempts {
      try? await Task.sleep(for: .milliseconds(500 * attempt))
      guard generation == captureGeneration, !stopping else { return }
      if await restartStream(generation: generation) {
        VaniLog.event(category: .capture, code: "meeting_capture_restarted")
        return
      }
    }
    guard generation == captureGeneration, !stopping else { return }
    captureStopped = true
    onFailure?(message)
  }

  /// Restarts capture when the microphone has gone quiet at the buffer level (no buffers,
  /// not silent audio), bounded so a microphone that never returns cannot cause a loop.
  private func checkMicrophone() async {
    guard isCapturing, !stopping, !restarting, let output else { return }
    let generation = captureGeneration
    let silence = await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: output.secondsSinceMicrophoneBuffer()) }
    }
    guard generation == captureGeneration, let silence else { return }
    if silence < 1 {
      silentMicrophoneRestarts = 0
      warnedAboutMicrophone = false
    }
    guard silence > Self.microphoneSilenceLimit else { return }
    guard silentMicrophoneRestarts < Self.maximumSilentMicrophoneRestarts else {
      if !warnedAboutMicrophone {
        warnedAboutMicrophone = true
        onWarning?(
          "Vani lost the microphone. Mac audio is still being recorded; reconnect a microphone to include your voice."
        )
      }
      return
    }
    silentMicrophoneRestarts += 1
    if await restartStream(generation: generation) {
      VaniLog.event(category: .capture, code: "meeting_microphone_restarted")
    }
  }

  /// Starts a replacement stream, then stops the one it replaces. The replaced stream keeps
  /// recording until the replacement delivers audio, and a replacement that cannot start
  /// leaves the current stream untouched.
  private func restartStream(generation: UInt64) async -> Bool {
    guard !restarting, let output, let previous = stream else { return false }
    restarting = true
    defer { restarting = false }
    do {
      let replacement = try await makeStream(output: output)
      guard generation == captureGeneration, !stopping else { return false }
      try await launch(replacement, output: output)
      guard generation == captureGeneration, !stopping else {
        try? await replacement.stopCapture()
        return false
      }
      stream = replacement
      streamFailed = false
      captureStopped = false
      try? await previous.stopCapture()
      return true
    } catch {
      return false
    }
  }
}

@available(macOS 15.0, *)
final class MeetingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked
  Sendable
{
  private var pending: [MeetingAudioSource: MeetingChunkBuffer] = [:]
  /// Each stream's place on the meeting timeline. A newer stream takes over at its first
  /// buffer; older streams are then ignored, so replacement never overlaps audio.
  private struct StreamTimeline {
    var origin: Double?
    var base: TimeInterval
    let order: Int
  }
  private var timelines: [ObjectIdentifier: StreamTimeline] = [:]
  private var nextOrder = 0
  private var activeOrder = -1
  private var latestOffset: TimeInterval = 0
  private var lastMicrophoneBuffer: ContinuousClock.Instant?
  private var currentStreamStartedAt = ContinuousClock().now
  private var failed = false
  private var closed = false
  private let directory: URL
  private let onChunk: @Sendable () -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onStopped: @Sendable (ObjectIdentifier, String) -> Void

  init(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void,
    onStopped: @escaping @Sendable (ObjectIdentifier, String) -> Void
  ) {
    self.directory = directory
    self.onChunk = onChunk
    self.onFailure = onFailure
    self.onStopped = onStopped
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    // Delegate callbacks may use another queue. The closure only forwards immutable information.
    onStopped(ObjectIdentifier(stream), "Meeting capture stopped: \(error.localizedDescription)")
  }

  /// Called on the sample queue before a stream starts. Its base is fixed at its first
  /// buffer, so a stream that starts late still continues after the latest audio.
  func registerStream(_ identity: ObjectIdentifier, continuingAt base: TimeInterval) {
    timelines[identity] = StreamTimeline(origin: nil, base: base, order: nextOrder)
    nextOrder += 1
    currentStreamStartedAt = ContinuousClock().now
    lastMicrophoneBuffer = nil
  }

  /// A stream that failed to start.
  func forgetStream(_ identity: ObjectIdentifier) {
    timelines[identity] = nil
  }

  /// Seconds since the current stream last delivered microphone audio, or since it began
  /// (allowing a few seconds for the microphone to start). Nil while within that grace.
  func secondsSinceMicrophoneBuffer(now: ContinuousClock.Instant = ContinuousClock().now)
    -> TimeInterval?
  {
    let reference = lastMicrophoneBuffer ?? currentStreamStartedAt
    let elapsed = now - reference
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    if lastMicrophoneBuffer == nil, seconds < 5 { return nil }
    return seconds
  }

  func noteMicrophoneBuffer(at instant: ContinuousClock.Instant = ContinuousClock().now) {
    lastMicrophoneBuffer = instant
  }

  /// Meeting time for a presentation timestamp from a registered stream, or nil for a
  /// replaced or unknown stream.
  func timelineOffset(for timestamp: Double, stream identity: ObjectIdentifier) -> TimeInterval? {
    guard var timeline = timelines[identity], timeline.order >= activeOrder else { return nil }
    if timeline.order > activeOrder {
      activeOrder = timeline.order
      timelines = timelines.filter { $0.value.order >= timeline.order }
    }
    if timeline.origin == nil {
      timeline.origin = timestamp
      timeline.base = max(timeline.base, latestOffset)
      timelines[identity] = timeline
    }
    let offset = timeline.base + max(0, timestamp - (timeline.origin ?? timestamp))
    latestOffset = max(latestOffset, offset)
    return offset
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !closed, !failed, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
      CMSampleBufferGetNumSamples(sampleBuffer) > 0, type == .audio || type == .microphone
    else {
      return
    }
    do {
      let source: MeetingAudioSource = type == .microphone ? .microphone : .system
      let (samples, rate) = try Self.samples(from: sampleBuffer)
      guard !samples.isEmpty else { return }
      let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      guard timestamp.isFinite else { throw MeetingError.invalidData }
      guard let offset = timelineOffset(for: timestamp, stream: ObjectIdentifier(stream)) else {
        return
      }
      if source == .microphone { noteMicrophoneBuffer() }
      guard offset < MeetingLimits.maximumDuration else {
        throw MeetingError.capture(
          "The four-hour recording limit was reached. Everything captured is saved; start a new meeting to continue."
        )
      }
      try append(samples, rate: rate, offset: offset, source: source)
    } catch {
      failed = true
      onFailure(error.localizedDescription)
    }
  }

  func append(_ samples: [Float], rate: Double, offset: TimeInterval, source: MeetingAudioSource)
    throws
  {
    if let buffer = pending[source], !buffer.samples.isEmpty,
      abs(buffer.rate - rate) > 0.5 || abs(offset - buffer.endOffset) > 0.5
    {
      try flush(source)
    }
    if pending[source]?.samples.isEmpty != false {
      pending[source] = MeetingChunkBuffer(rate: rate, offset: offset)
    }
    // Feed at most one second at a time, so a cut is always chosen before 25 seconds accumulate.
    let step = max(1, Int(rate))
    var start = 0
    while start < samples.count {
      let end = min(start + step, samples.count)
      // Mutate through Dictionary's modifying subscript. Copying the buffer first
      // shares its Array with the dictionary and copies the accumulated audio on every callback.
      let cut = pending[source]?.append(samples[start..<end])
      guard (pending[source]?.samples.count ?? 0) <= Int(rate * 25) else {
        throw MeetingError.capture(
          "Meeting audio could not be buffered safely. The saved audio is recoverable.")
      }
      if let cut { try flush(source, through: cut) }
      start = end
    }
  }

  func finish() throws {
    closed = true
    try flush(.microphone)
    try flush(.system)
  }

  /// Persists the first `count` samples (all by default). Pending audio changes only after the
  /// chunk file is durable, so a failed write can be retried by `finish()`.
  private func flush(_ source: MeetingAudioSource, through count: Int? = nil) throws {
    guard let buffer = pending[source], !buffer.samples.isEmpty else { return }
    let cut = min(count ?? buffer.samples.count, buffer.samples.count)
    let samples = try SampleRateConverter.convert(
      Array(buffer.samples[..<cut]), from: buffer.rate)
    let chunk = MeetingAudioChunk(source: source, offset: buffer.offset, samples: samples)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let file = directory.appendingPathComponent(chunk.fileName)
    try MeetingStore.write(encoder.encode(chunk), to: file)
    pending[source]?.removeFirst(cut)
    onChunk()
  }

  static func samples(from buffer: CMSampleBuffer) throws -> ([Float], Double) {
    guard let description = CMSampleBufferGetFormatDescription(buffer),
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
      format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
      format.mSampleRate > 0, format.mSampleRate <= 192_000,
      format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 8
    else { throw MeetingError.invalidData }
    let frames = CMSampleBufferGetNumSamples(buffer)
    guard frames > 0, frames <= Int(format.mSampleRate * 2) else { throw MeetingError.invalidData }
    let bufferCount =
      format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
      ? Int(format.mChannelsPerFrame) : 1
    let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
    defer { list.unsafeMutablePointer.deallocate() }
    var retained: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      buffer,
      bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
      bufferListSize: MemoryLayout<AudioBufferList>.size + (bufferCount - 1)
        * MemoryLayout<AudioBuffer>.size,
      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retained)
    guard status == noErr else { throw MeetingError.invalidData }
    let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    guard (float && format.mBitsPerChannel == 32) || (signed && format.mBitsPerChannel == 16) else {
      throw MeetingError.capture(
        "This microphone audio format is unsupported. Choose a standard PCM microphone and try again."
      )
    }
    var mono = [Float](repeating: 0, count: frames)
    for audioBuffer in list {
      let channels = Int(audioBuffer.mNumberChannels)
      let bytes = float ? 4 : 2
      guard channels > 0, let data = audioBuffer.mData,
        Int(audioBuffer.mDataByteSize) >= frames * channels * bytes
      else { throw MeetingError.invalidData }
      for frame in 0..<frames {
        for channel in 0..<channels {
          let index = frame * channels + channel
          let value =
            float
            ? data.assumingMemoryBound(to: Float.self)[index]
            : Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
          mono[frame] += value / Float(format.mChannelsPerFrame)
        }
      }
    }
    return (mono, format.mSampleRate)
  }
}

/// One source's unsaved audio. From 15 seconds it measures new 20 ms frames only and remembers
/// the quietest 200 ms window. A near-silent window is cut immediately; otherwise the quietest
/// window before 24 seconds is used, so chunk boundaries fall between words and stay below the
/// 25-second chunk and segment limits enforced by the store.
struct MeetingChunkBuffer {
  static let searchStart: TimeInterval = 15
  static let forcedCut: TimeInterval = 24
  static let quietRootMeanSquare = 0.005
  static let windowFrames = 10

  let rate: Double
  private(set) var offset: TimeInterval
  private(set) var samples: [Float] = []
  private var frameEnergies: [Double] = []
  private var analyzedThrough = 0
  private var windowEnergy: Double = 0
  private var quietest: (energy: Double, end: Int)?

  init(rate: Double, offset: TimeInterval) {
    self.rate = rate
    self.offset = offset
  }

  var endOffset: TimeInterval { offset + Double(samples.count) / rate }
  private var frameLength: Int { max(1, Int(rate * 0.02)) }

  /// Appends audio and returns the sample count of the chunk to persist now, if a cut is due.
  mutating func append(_ newSamples: ArraySlice<Float>) -> Int? {
    samples.append(contentsOf: newSamples)
    let frame = frameLength
    let limit = Int(rate * Self.forcedCut)
    analyzedThrough = max(analyzedThrough, Int(rate * Self.searchStart))
    while analyzedThrough + frame <= min(samples.count, limit) {
      var energy: Double = 0
      for index in analyzedThrough..<(analyzedThrough + frame) {
        energy += Double(samples[index] * samples[index])
      }
      frameEnergies.append(energy)
      windowEnergy += energy
      if frameEnergies.count > Self.windowFrames {
        windowEnergy -= frameEnergies[frameEnergies.count - Self.windowFrames - 1]
      }
      analyzedThrough += frame
      if frameEnergies.count >= Self.windowFrames, windowEnergy < quietest?.energy ?? .infinity {
        quietest = (max(0, windowEnergy), analyzedThrough)
      }
    }
    let middle = quietest.map { $0.end - Self.windowFrames / 2 * frame }
    if let quietest, let middle,
      (quietest.energy / Double(Self.windowFrames * frame)).squareRoot()
        <= Self.quietRootMeanSquare
    {
      return middle
    }
    return samples.count >= limit ? middle ?? limit : nil
  }

  /// Drops a persisted prefix and restarts silence analysis for the carried remainder.
  mutating func removeFirst(_ count: Int) {
    samples.removeFirst(count)
    offset += Double(count) / rate
    frameEnergies.removeAll(keepingCapacity: true)
    analyzedThrough = 0
    windowEnergy = 0
    quietest = nil
  }
}

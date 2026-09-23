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
  public var isCapturing: Bool { stream != nil && !captureStopped }
  private var stream: SCStream?
  private var output: MeetingStreamOutput?
  private var onFailure: (@Sendable (String) -> Void)?
  private var startedAt: ContinuousClock.Instant?
  private var restarting = false
  private var stopping = false
  private var watchdog: Task<Void, Never>?
  private var silentMicrophoneRestarts = 0
  /// Microphone buffers normally arrive every few milliseconds, silence included.
  static let microphoneSilenceLimit: TimeInterval = 2.5
  static let maximumSilentMicrophoneRestarts = 3
  private let queue = DispatchQueue(label: "com.mrinoy.vani.meeting-audio", qos: .userInitiated)
  static let restartAttempts = 3

  public init() {}

  public func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) async throws {
    guard stream == nil else { throw MeetingError.capture("A meeting is already recording.") }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw MeetingError.capture(
        "Allow Microphone access in System Settings before starting a meeting.")
    }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: onChunk, onFailure: onFailure,
      onStopped: { [weak self] message in
        Task { @MainActor in await self?.streamStopped(message) }
      })
    let stream = try await makeStream(output: output)
    self.output = output
    self.onFailure = onFailure
    self.stream = stream
    captureStopped = false
    stopping = false
    startedAt = ContinuousClock().now
    do { try await stream.startCapture() } catch {
      self.stream = nil
      self.output = nil
      throw error
    }
    silentMicrophoneRestarts = 0
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
    watchdog?.cancel()
    watchdog = nil
    // Retain both handles if stop fails; callers must not claim the microphone is released.
    if !captureStopped {
      try await stream.stopCapture()
      captureStopped = true
    }
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
    let identity = ObjectIdentifier(stream)
    let elapsed = elapsedTimeline
    // Enqueued before the stream starts, so its first buffer already uses the new timeline.
    queue.async { output.beginStream(identity, continuingAt: elapsed) }
    return stream
  }

  /// Seconds since the meeting started, used to place a restarted stream on the timeline.
  private var elapsedTimeline: TimeInterval {
    guard let startedAt else { return 0 }
    let elapsed = ContinuousClock().now - startedAt
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  /// The stream stopped with an error. Restart it; give up only after repeated failures.
  private func streamStopped(_ message: String) async {
    guard !stopping, stream != nil else { return }
    for attempt in 1...Self.restartAttempts {
      try? await Task.sleep(for: .milliseconds(500 * attempt))
      guard !stopping, stream != nil else { return }
      if await restartStream() {
        VaniLog.event(category: .capture, code: "meeting_capture_restarted")
        return
      }
    }
    captureStopped = true
    onFailure?(message)
  }

  /// Restarts capture when the microphone has gone quiet at the buffer level (no buffers,
  /// not silent audio), bounded so a microphone that never returns cannot cause a loop.
  private func checkMicrophone() async {
    guard isCapturing, !stopping, !restarting, let output else { return }
    let silence = await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: output.secondsSinceMicrophoneBuffer()) }
    }
    guard let silence else { return }
    if silence < 1 { silentMicrophoneRestarts = 0 }
    guard silence > Self.microphoneSilenceLimit,
      silentMicrophoneRestarts < Self.maximumSilentMicrophoneRestarts
    else { return }
    silentMicrophoneRestarts += 1
    if await restartStream() {
      VaniLog.event(category: .capture, code: "meeting_microphone_restarted")
    }
  }

  private func restartStream() async -> Bool {
    guard !restarting, let output, stream != nil else { return false }
    restarting = true
    defer { restarting = false }
    do {
      let replacement = try await makeStream(output: output)
      try await replacement.startCapture()
      guard !stopping else {
        try? await replacement.stopCapture()
        return false
      }
      stream = replacement
      captureStopped = false
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
  private var origin: Double?
  /// Meeting time at which the current stream began, and that stream's identity. Buffers
  /// from a replaced stream are ignored; the new stream continues the same timeline.
  private var timelineBase: TimeInterval = 0
  private var latestOffset: TimeInterval = 0
  private var lastMicrophoneBuffer: ContinuousClock.Instant?
  private var currentStreamStartedAt = ContinuousClock().now
  private var currentStream: ObjectIdentifier?
  private var failed = false
  private var closed = false
  private let directory: URL
  private let onChunk: @Sendable () -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onStopped: @Sendable (String) -> Void

  init(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void,
    onStopped: @escaping @Sendable (String) -> Void
  ) {
    self.directory = directory
    self.onChunk = onChunk
    self.onFailure = onFailure
    self.onStopped = onStopped
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    // Delegate callbacks may use another queue. The closure only forwards immutable information.
    onStopped("Meeting capture stopped: \(error.localizedDescription)")
  }

  /// Called on the sample queue before a (re)started stream delivers audio.
  func beginStream(_ identity: ObjectIdentifier, continuingAt base: TimeInterval) {
    currentStream = identity
    currentStreamStartedAt = ContinuousClock().now
    lastMicrophoneBuffer = nil
    origin = nil
    timelineBase = max(base, latestOffset)
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

  /// Meeting time for a presentation timestamp of the current stream.
  func timelineOffset(for timestamp: Double) -> TimeInterval {
    if origin == nil { origin = timestamp }
    let offset = timelineBase + max(0, timestamp - (origin ?? timestamp))
    latestOffset = max(latestOffset, offset)
    return offset
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !closed, !failed, currentStream == nil || currentStream == ObjectIdentifier(stream),
      sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
      CMSampleBufferGetNumSamples(sampleBuffer) > 0, type == .audio || type == .microphone
    else {
      return
    }
    do {
      let source: MeetingAudioSource = type == .microphone ? .microphone : .system
      if source == .microphone { noteMicrophoneBuffer() }
      let (samples, rate) = try Self.samples(from: sampleBuffer)
      guard !samples.isEmpty else { return }
      let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      guard timestamp.isFinite else { throw MeetingError.invalidData }
      let offset = timelineOffset(for: timestamp)
      guard offset < 2 * 60 * 60 else {
        throw MeetingError.capture(
          "The two-hour recording limit was reached. Stop this meeting and start a new one to continue."
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

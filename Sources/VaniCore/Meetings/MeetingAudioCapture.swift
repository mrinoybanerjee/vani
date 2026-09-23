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
@available(macOS 15.0, *)
@MainActor
public final class MeetingAudioCapture: MeetingAudioRecording {
  private var captureStopped = false
  public var isCapturing: Bool { stream != nil && !captureStopped }
  private var stream: SCStream?
  private var output: MeetingStreamOutput?
  private let queue = DispatchQueue(label: "com.mrinoy.vani.meeting-audio", qos: .userInitiated)

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
    configuration.captureMicrophone = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    let output = MeetingStreamOutput(
      directory: directory, onChunk: onChunk, onFailure: onFailure,
      onStopped: { [weak self] message in
        Task { @MainActor in
          self?.captureStopped = true
          onFailure(message)
        }
      })
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
    try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
    self.output = output
    self.stream = stream
    captureStopped = false
    do { try await stream.startCapture() } catch {
      self.stream = nil
      self.output = nil
      throw error
    }
  }

  public func stop() async throws {
    guard let stream, let output else { return }
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
}

@available(macOS 15.0, *)
final class MeetingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked
  Sendable
{
  private var pending: [MeetingAudioSource: MeetingChunkBuffer] = [:]
  private var origin: Double?
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
      if origin == nil { origin = timestamp }
      let offset = max(0, timestamp - (origin ?? timestamp))
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
    let file = directory.appendingPathComponent(chunk.id.uuidString).appendingPathExtension(
      "vani-audio")
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

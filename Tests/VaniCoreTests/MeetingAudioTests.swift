import AVFoundation
import CoreMedia
import Testing

@testable import VaniCore

struct MeetingAudioTests {
  @Test func aRestartedStreamContinuesTheMeetingTimeline() throws {
    guard #available(macOS 15.0, *) else { return }
    let output = MeetingStreamOutput(
      directory: FileManager.default.temporaryDirectory, onChunk: {}, onFailure: { _ in },
      onStopped: { _, _ in })
    // Keep the stand-in streams alive so their identities stay distinct.
    let streams = (NSObject(), NSObject(), NSObject())
    let first = ObjectIdentifier(streams.0)
    let second = ObjectIdentifier(streams.1)
    let failed = ObjectIdentifier(streams.2)
    defer { withExtendedLifetime(streams) {} }
    output.registerStream(first, continuingAt: 0)
    #expect(output.timelineOffset(for: 9_000, stream: first) == 0)
    #expect(output.timelineOffset(for: 9_004.5, stream: first) == 4.5)

    // A replacement that fails to start is forgotten and never shadows the live stream.
    output.registerStream(failed, continuingAt: 5)
    output.forgetStream(failed)
    #expect(output.timelineOffset(for: 9_006, stream: first) == 6)
    #expect(output.timelineOffset(for: 1, stream: failed) == nil)

    // The replacement registers early (base 5) but first delivers after the live stream
    // reached 6 s: it continues from 6, and the replaced stream is ignored from then on.
    output.registerStream(second, continuingAt: 5)
    #expect(output.timelineOffset(for: 9_006.5, stream: first) == 6.5)
    #expect(output.timelineOffset(for: 40, stream: second) == 6.5)
    #expect(output.timelineOffset(for: 43, stream: second) == 9.5)
    #expect(output.timelineOffset(for: 9_010, stream: first) == nil)
  }

  @Test func repeatedCallbacksPreserveBothSourcesAndFinalTails() throws {
    guard #available(macOS 15.0, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _, _ in })
    for index in 0..<1_010 {
      for source in [MeetingAudioSource.microphone, .system] {
        let value = Float(index % 10) / 10 * (source == .microphone ? 1 : -1)
        try output.append(
          [Float](repeating: value, count: 320), rate: 16_000,
          offset: Double(index) * 0.02, source: source)
      }
    }
    try output.finish()
    let chunks = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "vani-audio" }.map {
      try PropertyListDecoder().decode(MeetingAudioChunk.self, from: Data(contentsOf: $0))
    }
    // 20.2 seconds with no quiet window stays one chunk: cuts wait for silence or 24 seconds.
    #expect(chunks.count == 2)
    for source in [MeetingAudioSource.microphone, .system] {
      let ordered = chunks.filter { $0.source == source }.sorted { $0.offset < $1.offset }
      #expect(ordered.map(\.offset) == [0])
      #expect(try ordered.map { try $0.audio().samples.count } == [323_200])
      let samples = try ordered.flatMap { try $0.audio().samples }
      let expected = (0..<1_010).flatMap { index in
        [Float](
          repeating: Float(index % 10) / 10 * (source == .microphone ? 1 : -1), count: 320)
      }
      #expect(samples == expected)
    }
  }

  @Test func timestampGapAndRateChangeFlushExistingSamplesBeforeNextBuffer() throws {
    guard #available(macOS 15.0, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _, _ in })
    try output.append(
      [Float](repeating: 0.1, count: 16_000), rate: 16_000, offset: 0, source: .microphone)
    try output.append(
      [Float](repeating: 0.2, count: 16_000), rate: 16_000, offset: 5, source: .microphone)
    try output.append(
      [Float](repeating: 0.3, count: 48_000), rate: 48_000, offset: 6, source: .microphone)
    try output.finish()
    let chunks = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "vani-audio" }.map {
      try PropertyListDecoder().decode(MeetingAudioChunk.self, from: Data(contentsOf: $0))
    }.sorted { $0.offset < $1.offset }
    #expect(chunks.map(\.offset) == [0, 5, 6])
    #expect(try chunks.map { try $0.audio().samples.count } == [16_000, 16_000, 16_000])
    #expect(try chunks[0].audio().samples.allSatisfy { $0 == 0.1 })
    #expect(try chunks[1].audio().samples.allSatisfy { $0 == 0.2 })
    #expect(
      try chunks[2].audio().samples.dropFirst(100).dropLast(100).allSatisfy {
        abs($0 - 0.3) < 0.001
      })
  }

  private func buffer<T>(_ values: [T], rate: Double, channels: UInt32, flags: AudioFormatFlags)
    throws -> CMSampleBuffer
  {
    let stride: UInt32 = flags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : channels
    var format = AudioStreamBasicDescription(
      mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: flags | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(MemoryLayout<T>.size) * stride,
      mFramesPerPacket: 1, mBytesPerFrame: UInt32(MemoryLayout<T>.size) * stride,
      mChannelsPerFrame: channels, mBitsPerChannel: UInt32(MemoryLayout<T>.size * 8), mReserved: 0)
    var description: CMAudioFormatDescription?
    #expect(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description) == noErr)
    let audioDescription = try #require(description)
    let byteCount = values.count * MemoryLayout<T>.size
    var block: CMBlockBuffer?
    #expect(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount,
        flags: 0, blockBufferOut: &block) == noErr)
    let audioBlock = try #require(block)
    try values.withUnsafeBytes { bytes in
      let address = try #require(bytes.baseAddress)
      #expect(
        CMBlockBufferReplaceDataBytes(
          with: address, blockBuffer: audioBlock, offsetIntoDestination: 0, dataLength: byteCount)
          == noErr)
    }
    var sample: CMSampleBuffer?
    #expect(
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: audioBlock, formatDescription: audioDescription,
        sampleCount: values.count / Int(channels), presentationTimeStamp: .zero,
        packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }

  @Test func realCoreMediaBuffersDecodeAndDownmixWithoutChangingTimebase() throws {
    guard #available(macOS 15.0, *) else { return }
    let stereo = try buffer(
      [Float(0.2), 0.6, -0.4, 0.2], rate: 48_000, channels: 2, flags: kAudioFormatFlagIsFloat)
    let (floatSamples, rate) = try MeetingStreamOutput.samples(from: stereo)
    #expect(rate == 48_000 && floatSamples.count == 2)
    #expect(abs(floatSamples[0] - 0.4) < 0.0001 && abs(floatSamples[1] + 0.1) < 0.0001)
    let mono = try buffer(
      [Int16(16_384), -16_384], rate: 16_000, channels: 1, flags: kAudioFormatFlagIsSignedInteger)
    #expect(try MeetingStreamOutput.samples(from: mono).0 == [0.5, -0.5])
    let planar = try buffer(
      [Float(0.2), -0.4, 0.6, 0.2], rate: 48_000, channels: 2,
      flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved)
    let downmixed = try MeetingStreamOutput.samples(from: planar).0
    #expect(downmixed.count == 2)
    #expect(abs(downmixed[0] - 0.4) < 0.0001 && abs(downmixed[1] + 0.1) < 0.0001)
    let unsupported = try buffer(
      [Float(0.2)], rate: 16_000, channels: 1,
      flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian)
    #expect(throws: MeetingError.self) { try MeetingStreamOutput.samples(from: unsupported) }
  }

  private func savedChunks(in directory: URL) throws -> [MeetingAudioChunk] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "vani-audio" }
      .map { file in
        let chunk = try PropertyListDecoder().decode(
          MeetingAudioChunk.self, from: Data(contentsOf: file))
        // New chunk names carry the ID, source and offset used to order pending audio.
        #expect(file.lastPathComponent == chunk.fileName)
        let identity = MeetingAudioChunk.identity(fromFileName: file.lastPathComponent)
        #expect(identity?.id == chunk.id && identity?.source == chunk.source)
        #expect(abs((identity?.offset ?? -1) - chunk.offset) < 0.001)
        return chunk
      }
      .sorted { $0.offset < $1.offset }
  }

  /// Feeds 20 ms callbacks the way ScreenCaptureKit does, from a per-sample signal.
  @available(macOS 15.0, *)
  private func record(
    seconds: Double, offset: Double = 0, into output: MeetingStreamOutput,
    signal: (Int) -> Float
  ) throws -> [Float] {
    var all: [Float] = []
    for callback in 0..<Int(seconds * 50) {
      let samples = (0..<320).map { signal(callback * 320 + $0) }
      all += samples
      try output.append(
        samples, rate: 16_000, offset: offset + Double(callback) * 0.02, source: .microphone)
    }
    return all
  }

  @Test func chunksAreCutInTheMiddleOfTheFirstSilenceAfterFifteenSeconds() throws {
    guard #available(macOS 15.0, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _, _ in })
    // Speech-like tone, with a pause at 10 s (too early to cut) and at 17.0–17.5 s.
    let input = try record(seconds: 22, offset: 3, into: output) { index in
      let time = Double(index) / 16_000
      let paused = (10..<10.5).contains(time) || (17..<17.5).contains(time)
      return paused ? 0 : 0.3 * Float(sin(Double(index) * 0.05))
    }
    #expect(try savedChunks(in: directory).count == 1)
    try output.finish()
    let chunks = try savedChunks(in: directory)
    // The first fully silent 200 ms window ends at 17.2 s; the cut lands in its middle.
    #expect(try chunks.map { try $0.audio().samples.count } == [273_600, 352_000 - 273_600])
    #expect(chunks.map(\.offset) == [3, 3 + 17.1])
    #expect(try chunks.flatMap { try $0.audio().samples } == input)
  }

  @Test func withoutSilenceTheQuietestWindowIsCutBeforeTwentyFourSeconds() throws {
    guard #available(macOS 15.0, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _, _ in })
    // Continuous speech with a softer (not silent) 200 ms at 20.0 s, then 30 s total.
    let input = try record(seconds: 30, into: output) { index in
      let time = Double(index) / 16_000
      return ((20..<20.2).contains(time) ? 0.05 : 0.3) * Float(sin(Double(index) * 0.05))
    }
    try output.finish()
    let chunks = try savedChunks(in: directory)
    #expect(try chunks.map { try $0.audio().samples.count } == [321_600, 480_000 - 321_600])
    #expect(chunks.map(\.offset) == [0, 20.1])
    #expect(try chunks.flatMap { try $0.audio().samples } == input)
    #expect(try chunks.allSatisfy { try $0.audio().duration <= MeetingChunkBuffer.forcedCut })
  }

  @Test func chunkBufferCarriesRemainderOffsetAndRestartsAnalysis() {
    var buffer = MeetingChunkBuffer(rate: 16_000, offset: 5)
    let loud = [Float](repeating: 0.25, count: 16_000)
    var cut: Int?
    for _ in 0..<24 where cut == nil { cut = buffer.append(loud[...]) }
    // Uniform audio has no quieter window, so the first complete window after 15 s is used.
    #expect(cut == 15 * 16_000 + 1_600)
    buffer.removeFirst(cut ?? 0)
    #expect(buffer.offset == 5 + 15.1)
    #expect(buffer.samples.count == 24 * 16_000 - 241_600)
    #expect(abs(buffer.endOffset - 29) < 0.000_001)
    // The 8.9 s remainder is below the analysis start, so it is not cut again yet.
    #expect(buffer.append(loud[..<1_000]) == nil)
  }

  @Test func loudestFrameFindsQuietSpeechThatAWholeChunkAverageHides() {
    var samples = [Float](repeating: 0, count: 20 * 16_000)
    for index in 100_000..<108_000 { samples[index] = 0.012 * Float(sin(Double(index) * 0.07)) }
    let audio = CapturedAudio(samples: samples)
    #expect(audio.rootMeanSquare < 0.0015)
    #expect(CapturedAudio(samples: samples).loudestFrameRootMeanSquare > 0.008)
    #expect(
      CapturedAudio(samples: [Float](repeating: 0.001, count: 16_000)).loudestFrameRootMeanSquare
        < 0.004)
    #expect(CapturedAudio(samples: []).loudestFrameRootMeanSquare == 0)
  }
}

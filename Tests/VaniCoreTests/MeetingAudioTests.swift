import AVFoundation
import CoreMedia
import Testing

@testable import VaniCore

struct MeetingAudioTests {
  @Test func repeatedCallbacksPreserveBothSourcesAndFinalTails() throws {
    guard #available(macOS 15.0, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = MeetingStreamOutput(
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _ in })
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
    #expect(chunks.count == 4)
    for source in [MeetingAudioSource.microphone, .system] {
      let ordered = chunks.filter { $0.source == source }.sorted { $0.offset < $1.offset }
      #expect(ordered.map(\.offset) == [0, 20])
      #expect(try ordered.map { try $0.audio().samples.count } == [320_000, 3_200])
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
      directory: directory, onChunk: {}, onFailure: { _ in }, onStopped: { _ in })
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
}

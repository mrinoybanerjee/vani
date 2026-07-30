import AVFoundation
import Testing

@testable import VaniCore

@Test
func boundedAudioBufferPreservesOrderAndReportsOverflow() throws {
  let ringBuffer = AudioSampleRingBuffer()
  ringBuffer.reset(capacity: 3, sampleRate: 48_000)

  ringBuffer.append(try audioBuffer(samples: [0.1, 0.2]))
  ringBuffer.append(try audioBuffer(samples: [0.3, 0.4]))

  let snapshot = ringBuffer.snapshot()
  #expect(snapshot.samples == [0.1, 0.2, 0.3])
  #expect(snapshot.sampleRate == 48_000)
  #expect(snapshot.overflowed)
}

@Test
func boundedAudioBufferResetClearsSamplesAndOverflow() throws {
  let ringBuffer = AudioSampleRingBuffer()
  ringBuffer.reset(capacity: 1, sampleRate: 48_000)
  ringBuffer.append(try audioBuffer(samples: [0.1, 0.2]))
  #expect(ringBuffer.snapshot().overflowed)

  ringBuffer.reset(capacity: 4, sampleRate: 16_000)

  let snapshot = ringBuffer.snapshot()
  #expect(snapshot.samples.isEmpty)
  #expect(snapshot.sampleRate == 16_000)
  #expect(!snapshot.overflowed)
}

private func audioBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 1,
      interleaved: false
    )
  )
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(samples.count)
    )
  )
  buffer.frameLength = buffer.frameCapacity
  buffer.floatChannelData?.pointee.update(from: samples, count: samples.count)
  return buffer
}

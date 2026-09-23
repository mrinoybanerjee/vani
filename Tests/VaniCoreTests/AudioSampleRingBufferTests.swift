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

@Test
func pagedAudioBufferReservesCapacityWithoutChangingCapturedSamples() throws {
  let ringBuffer = AudioSampleRingBuffer()
  let generation = ringBuffer.reset(
    capacity: 2,
    maximumCapacity: 5,
    chunkCapacity: 2,
    sampleRate: 48_000
  )

  #expect(ringBuffer.reserveNextChunk(generation: generation))
  ringBuffer.append(try audioBuffer(samples: [0.1, 0.2, 0.3, 0.4]))

  var snapshot = ringBuffer.snapshot()
  #expect(snapshot.samples == [0.1, 0.2, 0.3, 0.4])
  #expect(!snapshot.overflowed)

  #expect(ringBuffer.reserveNextChunk(generation: generation))
  #expect(!ringBuffer.reserveNextChunk(generation: generation))
  ringBuffer.append(try audioBuffer(samples: [0.5, 0.6]))

  snapshot = ringBuffer.drain()
  #expect(snapshot.samples == [0.1, 0.2, 0.3, 0.4, 0.5])
  #expect(snapshot.overflowed)
  #expect(ringBuffer.snapshot().samples.isEmpty)
}

@Test
func staleAudioBufferReservationCannotMutateANewCapture() {
  let ringBuffer = AudioSampleRingBuffer()
  let staleGeneration = ringBuffer.reset(
    capacity: 2,
    maximumCapacity: 4,
    chunkCapacity: 2,
    sampleRate: 48_000
  )
  ringBuffer.reset(capacity: 1, sampleRate: 16_000)

  #expect(!ringBuffer.reserveNextChunk(generation: staleGeneration))
  let snapshot = ringBuffer.snapshot()
  #expect(snapshot.samples.isEmpty)
  #expect(snapshot.sampleRate == 16_000)
}

@Test
func overflowedCaptureRemainsAvailableForTranscription() throws {
  let ringBuffer = AudioSampleRingBuffer()
  ringBuffer.reset(capacity: 3, sampleRate: 16_000)
  ringBuffer.append(try audioBuffer(samples: [0.1, 0.2, 0.3, 0.4]))

  let audio = try AVAudioEngineCapture.makeCapturedAudio(from: ringBuffer.drain())

  #expect(!audio.samples.isEmpty)
  #expect(audio.wasTruncated)
}

@Test
func longCaptureRejectsInputRatesAboveTheBoundedMemoryProfile() throws {
  try AVAudioEngineCapture.validateInputSampleRate(48_000)
  #expect(throws: VaniFailure.unsupportedInputSampleRate) {
    try AVAudioEngineCapture.validateInputSampleRate(96_000)
  }
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_RUN_LONG_AUDIO_TESTS"] == "1",
    "Allocates and converts the full 20-minute capture boundary"
  )
)
func twentyMinutePagedCaptureDrainsAndResamples() throws {
  let sampleRate = 48_000
  let pageFrames = sampleRate * 60
  let maximumFrames = sampleRate * 20 * 60
  let ringBuffer = AudioSampleRingBuffer()
  let generation = ringBuffer.reset(
    capacity: pageFrames * 3,
    maximumCapacity: maximumFrames,
    chunkCapacity: pageFrames,
    sampleRate: Double(sampleRate)
  )
  while ringBuffer.reserveNextChunk(generation: generation) {}

  let tapBuffer = try audioBuffer(samples: Array(repeating: 0.05, count: 1_024))
  for _ in 0..<(maximumFrames / 1_024) {
    ringBuffer.append(tapBuffer)
  }
  ringBuffer.append(tapBuffer)

  let audio = try AVAudioEngineCapture.makeCapturedAudio(from: ringBuffer.drain())

  #expect(abs(audio.duration - 20 * 60) < 0.01)
  #expect(audio.wasTruncated)
  #expect(audio.rootMeanSquare > 0.0015)
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

@Test
func multichannelInputIsAveragedSoAVoiceOnAnyChannelIsCaptured() throws {
  let ringBuffer = AudioSampleRingBuffer()
  ringBuffer.reset(capacity: 4, sampleRate: 16_000)
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
  buffer.frameLength = 4
  let channels = try #require(buffer.floatChannelData)
  for frame in 0..<4 {
    channels[0][frame] = 0
    channels[1][frame] = 0.5
  }

  ringBuffer.append(buffer)

  #expect(ringBuffer.drain().samples == [0.25, 0.25, 0.25, 0.25])
}

@Test
func briefClipsArePaddedToOneSecondForInference() {
  let brief = [Float](repeating: 0.1, count: 3_200)
  let padded = FluidAudioSpeechRecognizer.paddedForInference(brief)
  #expect(padded.count == CapturedAudio.targetSampleRate)
  #expect(Array(padded.prefix(3_200)) == brief)
  let long = [Float](repeating: 0.1, count: 20_000)
  #expect(FluidAudioSpeechRecognizer.paddedForInference(long) == long)
}

@Test
func segmentsRecordedAtDifferentRatesAreJoinedInOrderAt16kHz() throws {
  let first = AudioSampleRingBuffer.Snapshot(
    samples: [Float](repeating: 0.25, count: 48_000), sampleRate: 48_000, overflowed: false)
  let second = AudioSampleRingBuffer.Snapshot(
    samples: [Float](repeating: -0.25, count: 24_000), sampleRate: 24_000, overflowed: false)
  let audio = try AVAudioEngineCapture.makeCapturedAudio(from: [first, second])

  #expect(abs(audio.samples.count - 32_000) <= 64)
  #expect(!audio.wasTruncated)
  // First second is the 48 kHz segment, then the 24 kHz one, in order.
  #expect(audio.samples[8_000] > 0.2)
  #expect(audio.samples[24_000] < -0.2)

  let truncated = AudioSampleRingBuffer.Snapshot(
    samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, overflowed: true)
  #expect(try AVAudioEngineCapture.makeCapturedAudio(from: [first, truncated]).wasTruncated)
}

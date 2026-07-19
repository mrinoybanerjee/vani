import AVFoundation
import Foundation
import Testing

@testable import VaniCore

@Test
func acceptsAudibleRecordingInsideBounds() throws {
  let audio = CapturedAudio(samples: Array(repeating: 0.05, count: 8_000))
  try AudioPolicy.default.validate(audio)
}

@Test
func rejectsShortRecording() {
  let audio = CapturedAudio(samples: Array(repeating: 0.05, count: 1_000))
  #expect(throws: VaniFailure.recordingTooShort) {
    try AudioPolicy.default.validate(audio)
  }
}

@Test
func rejectsSilence() {
  let audio = CapturedAudio(samples: Array(repeating: 0, count: 8_000))
  #expect(throws: VaniFailure.noSpeechDetected) {
    try AudioPolicy.default.validate(audio)
  }
}

@Test
func computesAudioMetrics() {
  let audio = CapturedAudio(samples: [-0.5, 0.25, 0.5, -0.25], sampleRate: 4)
  #expect(abs(audio.duration - 1) < 0.0001)
  #expect(abs(audio.peakAmplitude - 0.5) < 0.0001)
  #expect(abs(audio.rootMeanSquare - 0.39528) < 0.0001)
}

@Test
func loadsAndResamplesAnAudioFixture() throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "quick-brown-fox",
      withExtension: "wav",
      subdirectory: "Fixtures"
    )
  )

  let audio = try AudioFileLoader.load(fixture)

  #expect(audio.sampleRate == CapturedAudio.targetSampleRate)
  #expect(audio.duration > 1)
  #expect(audio.rootMeanSquare > 0.0015)
}

import Foundation
import Testing

@testable import VaniCore

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_RUN_MODEL_TESTS"] == "1",
    "Requires the downloaded local speech model"
  )
)
func bundledEnglishFixtureTranscribesLocally() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "librispeech-1272-128104-0000",
      withExtension: "wav",
      subdirectory: "Fixtures"
    )
  )
  let recognizer = FluidAudioSpeechRecognizer()
  try await recognizer.prepare { _ in }

  let result = try await recognizer.transcribe(AudioFileLoader.load(fixture))
  let normalized = result.text.lowercased()

  #expect(normalized.contains("mister quilter"))
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_RUN_LONG_MODEL_TESTS"] == "1",
    "Requires the downloaded local speech model and runs a 20-minute transcription"
  )
)
func twentyMinuteEnglishFixtureTranscribesLocally() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "librispeech-1272-128104-0000",
      withExtension: "wav",
      subdirectory: "Fixtures"
    )
  )
  let source = try AudioFileLoader.load(fixture).samples
  let targetCount = 20 * 60 * CapturedAudio.targetSampleRate
  var samples: [Float] = []
  samples.reserveCapacity(targetCount)
  while samples.count < targetCount {
    samples.append(contentsOf: source.prefix(targetCount - samples.count))
  }

  let recognizer = FluidAudioSpeechRecognizer()
  try await recognizer.prepare { _ in }
  let result = try await recognizer.transcribe(CapturedAudio(samples: samples))

  #expect(!result.text.isEmpty)
}

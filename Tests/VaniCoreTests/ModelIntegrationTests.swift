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

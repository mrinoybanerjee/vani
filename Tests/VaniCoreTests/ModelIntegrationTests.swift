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
  print("VANI_BASE_PROCESSING_SECONDS=\(result.processingDuration)")
  let normalized = result.text.lowercased()

  #expect(normalized.contains("mister quilter"))
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_RUN_PERSONALIZATION_MODEL_TESTS"] == "1",
    "Downloads and exercises the optional local personalization model in Release builds"
  )
)
func bundledEnglishFixtureExercisesAcousticPersonalization() async throws {
  #expect(FluidAudioSpeechRecognizer.acousticPersonalizationAvailableInCurrentBuild)
  let fixture = try #require(
    Bundle.module.url(
      forResource: "librispeech-1272-128104-0000",
      withExtension: "wav",
      subdirectory: "Fixtures"
    )
  )
  let recognizer = FluidAudioSpeechRecognizer()
  try await recognizer.prepare { _ in }
  try await recognizer.preparePersonalizationModels { _ in }
  #expect(await recognizer.personalizationModelsAreInstalled())

  let audio = try AudioFileLoader.load(fixture)
  let baseline = try await recognizer.transcribe(audio)
  let result = try await recognizer.transcribe(
    audio,
    context: SpeechRecognitionContext(
      personalizedTerms: [
        SpeechPersonalizationTerm(
          canonical: "Mister Quilter",
          aliases: ["mister quilter"]
        )
      ]
    )
  )

  #expect(result.acousticPersonalizationAttempted)
  #expect(result.rawText?.lowercased().contains("mister quilter") == true)
  #expect(result.text.lowercased().contains("mister quilter"))
  #expect(result.processingDuration < result.audioDuration)

  let absentTermResult = try await recognizer.transcribe(
    audio,
    context: SpeechRecognitionContext(
      personalizedTerms: [
        SpeechPersonalizationTerm(canonical: "TensorRT", aliases: ["tensor art"])
      ]
    )
  )
  #expect(absentTermResult.acousticPersonalizationAttempted)
  #expect(absentTermResult.text == baseline.text)
  #expect(absentTermResult.processingDuration < absentTermResult.audioDuration)
  print("VANI_CTC_BASE_PROCESSING_SECONDS=\(baseline.processingDuration)")
  print("VANI_CTC_POSITIVE_PROCESSING_SECONDS=\(result.processingDuration)")
  print("VANI_CTC_NEGATIVE_PROCESSING_SECONDS=\(absentTermResult.processingDuration)")
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

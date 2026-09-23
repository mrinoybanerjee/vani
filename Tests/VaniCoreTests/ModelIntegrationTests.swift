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

  // Uses Parakeet Unified when VANI_UNIFIED_MODEL_DIR points at a verified copy.
  let recognizer =
    unifiedModelDirectoryForTesting.map { FluidAudioSpeechRecognizer(unifiedModelDirectory: $0) }
    ?? FluidAudioSpeechRecognizer()
  try await recognizer.prepare { _ in }
  let result = try await recognizer.transcribe(CapturedAudio(samples: samples))
  print("VANI_LONG_MODEL=\(String(describing: await recognizer.activeModel()))")
  print("VANI_LONG_PROCESSING_SECONDS=\(result.processingDuration)")

  #expect(!result.text.isEmpty)
}

private var unifiedModelDirectoryForTesting: URL? {
  ProcessInfo.processInfo.environment["VANI_UNIFIED_MODEL_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_UNIFIED_MODEL_DIR"] != nil,
    "Requires a verified Parakeet Unified model directory"
  )
)
func parakeetUnifiedIsPreferredAndTranscribesTheFixture() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "librispeech-1272-128104-0000", withExtension: "wav",
      subdirectory: "Fixtures"))
  let directory = try #require(unifiedModelDirectoryForTesting)
  let recognizer = FluidAudioSpeechRecognizer(unifiedModelDirectory: directory)
  #expect(await recognizer.preferredModelIsInstalled())
  try await recognizer.prepare { _ in }
  #expect(await recognizer.activeModel() == .parakeetUnified)

  let audio = try AudioFileLoader.load(fixture)
  let result = try await recognizer.transcribe(audio)
  print("VANI_UNIFIED_TEXT=\(result.text)")
  print("VANI_UNIFIED_PROCESSING_SECONDS=\(result.processingDuration)")
  #expect(result.text.lowercased().contains("quilter"))
  #expect(result.text.lowercased().contains("apostle of the middle classes"))

  // Brief words below the encoder's 0.3 s floor are padded rather than failing.
  let brief = CapturedAudio(samples: Array(audio.samples.prefix(3_200)))
  _ = try await recognizer.transcribe(brief)

  #if !DEBUG
    if await recognizer.personalizationModelsAreInstalled() {
      let boosted = try await recognizer.transcribe(
        audio,
        context: SpeechRecognitionContext(personalizedTerms: [
          SpeechPersonalizationTerm(canonical: "Quilter", aliases: ["quilter"])
        ]))
      print("VANI_UNIFIED_BOOSTED_TEXT=\(boosted.text)")
      #expect(boosted.acousticPersonalizationAttempted)
      #expect(boosted.text.lowercased().contains("quilter"))
    }
  #endif
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["VANI_RUN_MODEL_TESTS"] == "1",
    "Requires the downloaded Parakeet TDT v2 model"
  )
)
func previousModelRemainsTheFallbackWhenUnifiedIsAbsent() async throws {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let recognizer = FluidAudioSpeechRecognizer(unifiedModelDirectory: missing)
  #expect(!(await recognizer.preferredModelIsInstalled()))
  #expect(await recognizer.modelsAreInstalled())
  try await recognizer.prepare { _ in }
  #expect(await recognizer.activeModel() == .parakeetTDTv2)
}

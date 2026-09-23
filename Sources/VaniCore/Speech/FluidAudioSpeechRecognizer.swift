import CoreML
import FluidAudio
import Foundation

public actor FluidAudioSpeechRecognizer: SpeechRecognizing {
  public static let modelVersion: AsrModelVersion = .v2

  public static var acousticPersonalizationAvailableInCurrentBuild: Bool {
    #if DEBUG
      false
    #else
      true
    #endif
  }

  private let modelDownloader: PinnedModelDownloader
  private let personalizationModelDownloader: PinnedModelDownloader
  private var manager: AsrManager?
  private var ctcModels: CtcModels?
  private var ctcTokenizer: CtcTokenizer?
  private var personalizationUnloadTask: Task<Void, Never>?
  private var personalizationLoadTask: Task<(CtcModels, CtcTokenizer), Error>?
  private var cachedRescorer: PreparedRescorer?

  private struct PreparedRescorer {
    let terms: [SpeechPersonalizationTerm]
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
  }
  private var personalizationUnloadGeneration: UInt64 = 0
  private var decoderLayerCount = 2
  private var integrityVerified = false
  private var personalizationIntegrityVerified = false

  public init() {
    modelDownloader = PinnedModelDownloader(
      repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
      revision: ModelIntegrityVerifier.parakeetV2Revision,
      verifier: .parakeetV2
    )
    personalizationModelDownloader = PinnedModelDownloader(
      repository: "FluidInference/parakeet-ctc-110m-coreml",
      revision: ModelIntegrityVerifier.parakeetCtc110MRevision,
      verifier: .parakeetCtc110M
    )
  }

  public func modelsAreInstalled() async -> Bool {
    let directory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
    guard AsrModels.modelsExist(at: directory, version: Self.modelVersion) else {
      integrityVerified = false
      return false
    }
    if integrityVerified { return true }
    do {
      try ModelIntegrityVerifier.parakeetV2.verify(directory: directory)
      integrityVerified = true
      return true
    } catch {
      integrityVerified = false
      return false
    }
  }

  public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    guard SystemInfo.isAppleSilicon else {
      throw VaniFailure.unsupportedHardware
    }
    if manager != nil {
      progress(1)
      return
    }

    do {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      let directory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
      var needsDownload = !AsrModels.modelsExist(at: directory, version: Self.modelVersion)
      if AsrModels.modelsExist(at: directory, version: Self.modelVersion), !integrityVerified {
        do {
          try ModelIntegrityVerifier.parakeetV2.verify(directory: directory)
          integrityVerified = true
        } catch {
          needsDownload = true
        }
      }

      if needsDownload {
        try await modelDownloader.install(at: directory) { downloadProgress in
          progress(min(max(downloadProgress * 0.6, 0), 0.6))
        }
      }

      progress(0.65)
      if needsDownload || !integrityVerified {
        try ModelIntegrityVerifier.parakeetV2.verify(directory: directory)
        integrityVerified = true
      }

      let models = try await AsrModels.load(
        from: directory,
        configuration: configuration,
        version: Self.modelVersion,
        progressHandler: { download in
          progress(0.65 + min(max(download.fractionCompleted, 0), 1) * 0.35)
        }
      )
      let manager = AsrManager(config: .default, models: models)
      decoderLayerCount = await manager.decoderLayerCount
      self.manager = manager
      progress(1)
    } catch let failure as VaniFailure {
      throw failure
    } catch {
      let installed = await modelsAreInstalled()
      throw installed ? VaniFailure.modelLoadFailed : VaniFailure.modelDownloadFailed
    }
  }

  public func personalizationModelsAreInstalled() async -> Bool {
    let directory = Self.personalizationModelDirectory
    guard CtcModels.modelsExist(at: directory) else {
      personalizationIntegrityVerified = false
      return false
    }
    if personalizationIntegrityVerified { return true }
    do {
      try ModelIntegrityVerifier.parakeetCtc110M.verify(directory: directory)
      personalizationIntegrityVerified = true
      return true
    } catch {
      personalizationIntegrityVerified = false
      return false
    }
  }

  public func preparePersonalizationModels(
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard SystemInfo.isAppleSilicon else {
      throw VaniFailure.unsupportedHardware
    }
    let directory = Self.personalizationModelDirectory
    do {
      if !(await personalizationModelsAreInstalled()) {
        try await personalizationModelDownloader.install(at: directory, progress: progress)
      }
      try ModelIntegrityVerifier.parakeetCtc110M.verify(directory: directory)
      personalizationIntegrityVerified = true
      progress(0.95)
      _ = try await loadPersonalizationModelsIfNeeded()
      progress(1)
      schedulePersonalizationUnload()
    } catch let failure as VaniFailure {
      throw failure
    } catch {
      throw await personalizationModelsAreInstalled()
        ? VaniFailure.modelLoadFailed
        : VaniFailure.modelDownloadFailed
    }
  }

  public func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult {
    let result = try await transcribeBase(audio)
    return speechResult(from: result, text: result.text)
  }

  public func transcribe(
    _ audio: CapturedAudio,
    context: SpeechRecognitionContext
  ) async throws -> SpeechResult {
    let startedAt = Date()
    let baseResult = try await transcribeBase(audio)
    guard !context.personalizedTerms.isEmpty else {
      return speechResult(
        from: baseResult,
        text: baseResult.text,
        processingDuration: Date().timeIntervalSince(startedAt)
      )
    }

    #if DEBUG
      // FluidAudio 0.15.5 hard-enables transcript-bearing debug logs inside its
      // CTC rescorer. Never invoke that path in a Vani Debug build.
      return speechResult(
        from: baseResult,
        text: baseResult.text,
        processingDuration: Date().timeIntervalSince(startedAt)
      )
    #else
      guard await personalizationModelsAreInstalled(), let tokenTimings = baseResult.tokenTimings,
        !tokenTimings.isEmpty
      else {
        return speechResult(
          from: baseResult,
          text: baseResult.text,
          processingDuration: Date().timeIntervalSince(startedAt)
        )
      }

      do {
        let (models, tokenizer) = try await loadPersonalizationModelsIfNeeded()
        guard
          let prepared = try await personalizationRescorer(
            for: context.personalizedTerms, models: models, tokenizer: tokenizer)
        else {
          return speechResult(
            from: baseResult,
            text: baseResult.text,
            processingDuration: Date().timeIntervalSince(startedAt)
          )
        }
        let spotted = try await prepared.spotter.spotKeywordsWithLogProbs(
          audioSamples: audio.samples,
          customVocabulary: prepared.vocabulary
        )
        guard !spotted.logProbs.isEmpty else {
          schedulePersonalizationUnload()
          return speechResult(from: baseResult, text: baseResult.text)
        }
        let rescorer = prepared.rescorer
        let rescored = rescorer.ctcTokenRescore(
          transcript: baseResult.text,
          tokenTimings: tokenTimings,
          logProbs: spotted.logProbs,
          frameDuration: spotted.frameDuration,
          minSimilarity: 0.60
        )
        schedulePersonalizationUnload()
        let text = rescored.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return speechResult(
          from: baseResult,
          text: text.isEmpty ? baseResult.text : text,
          processingDuration: Date().timeIntervalSince(startedAt),
          acousticPersonalizationAttempted: true
        )
      } catch {
        // Personalization is optional. A successful base transcript always wins
        // over an auxiliary-model failure.
        schedulePersonalizationUnload()
        return speechResult(
          from: baseResult,
          text: baseResult.text,
          processingDuration: Date().timeIntervalSince(startedAt)
        )
      }
    #endif
  }

  private func transcribeBase(_ audio: CapturedAudio) async throws -> ASRResult {
    guard let manager else {
      throw VaniFailure.modelUnavailable
    }
    guard audio.sampleRate == CapturedAudio.targetSampleRate else {
      throw VaniFailure.audioCaptureFailed
    }

    do {
      var decoderState = try TdtDecoderState(decoderLayers: decoderLayerCount)
      let result = try await manager.transcribe(
        Self.paddedForInference(audio.samples),
        decoderState: &decoderState
      )
      return result
    } catch {
      throw VaniFailure.transcriptionFailed
    }
  }

  /// The encoder rejects clips shorter than 0.3 s, while Vani accepts brief words such as
  /// "yes". Trailing silence changes no speech and is free: inference pads to 15 s anyway.
  static let minimumInferenceSampleCount = CapturedAudio.targetSampleRate

  static func paddedForInference(_ samples: [Float]) -> [Float] {
    guard samples.count < minimumInferenceSampleCount else { return samples }
    return samples + [Float](repeating: 0, count: minimumInferenceSampleCount - samples.count)
  }

  private func speechResult(
    from result: ASRResult,
    text: String,
    processingDuration: TimeInterval? = nil,
    acousticPersonalizationAttempted: Bool = false
  ) -> SpeechResult {
    SpeechResult(
      text: text,
      rawText: result.text,
      confidence: result.confidence,
      audioDuration: result.duration,
      processingDuration: processingDuration ?? result.processingTime,
      acousticPersonalizationAttempted: acousticPersonalizationAttempted
    )
  }

  /// Loads the optional CTC model once; concurrent callers share the same load.
  private func loadPersonalizationModelsIfNeeded() async throws -> (CtcModels, CtcTokenizer) {
    if let ctcModels, let ctcTokenizer {
      return (ctcModels, ctcTokenizer)
    }
    if let personalizationLoadTask {
      return try await personalizationLoadTask.value
    }
    let directory = Self.personalizationModelDirectory
    let verified = personalizationIntegrityVerified
    let task = Task { () throws -> (CtcModels, CtcTokenizer) in
      if !verified {
        try ModelIntegrityVerifier.parakeetCtc110M.verify(directory: directory)
      }
      let models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
      let tokenizer = try await CtcTokenizer.load(from: directory)
      return (models, tokenizer)
    }
    personalizationLoadTask = task
    defer { personalizationLoadTask = nil }
    let loaded = try await task.value
    personalizationIntegrityVerified = true
    ctcModels = loaded.0
    ctcTokenizer = loaded.1
    return loaded
  }

  /// Terms change only when corrections change, so the tokenized vocabulary and
  /// rescorer (which otherwise re-parses tokenizer.json) are reused across dictations.
  private func personalizationRescorer(
    for personalizedTerms: [SpeechPersonalizationTerm],
    models: CtcModels,
    tokenizer: CtcTokenizer
  ) async throws -> PreparedRescorer? {
    if let cachedRescorer, cachedRescorer.terms == personalizedTerms {
      return cachedRescorer
    }
    let terms = personalizedTerms.compactMap { term -> CustomVocabularyTerm? in
      let tokenIDs = tokenizer.encode(term.canonical)
      guard !tokenIDs.isEmpty else { return nil }
      return CustomVocabularyTerm(
        text: term.canonical,
        aliases: term.aliases.isEmpty ? nil : term.aliases,
        ctcTokenIds: tokenIDs,
        minSimilarity: 0.60
      )
    }
    guard !terms.isEmpty else { return nil }
    let vocabulary = CustomVocabularyContext(
      terms: terms,
      minSimilarity: 0.60,
      minTermLength: 4
    )
    let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
    let rescorer = try await VocabularyRescorer.create(
      spotter: spotter,
      vocabulary: vocabulary,
      config: VocabularyRescorer.Config(
        useAdaptiveThresholds: true,
        referenceTokenCount: 3,
        shortTermCbwTaperPivot: 5,
        shortTermCbwTaperExponent: 2,
        spotterRescueMinSimilarity: 0.50,
        spotterRescueMultiWordMinSimilarity: 0.60,
        spotterRescueEnabled: false
      ),
      ctcModelDirectory: Self.personalizationModelDirectory
    )
    let prepared = PreparedRescorer(
      terms: personalizedTerms, vocabulary: vocabulary, spotter: spotter, rescorer: rescorer)
    cachedRescorer = prepared
    return prepared
  }

  /// Warms the optional model while the user is still speaking, so acoustic
  /// personalization does not add model loading after the shortcut is released.
  public func prewarmPersonalization() async {
    guard Self.acousticPersonalizationAvailableInCurrentBuild,
      await personalizationModelsAreInstalled()
    else { return }
    _ = try? await loadPersonalizationModelsIfNeeded()
    schedulePersonalizationUnload()
  }

  private func schedulePersonalizationUnload() {
    personalizationUnloadGeneration &+= 1
    let generation = personalizationUnloadGeneration
    personalizationUnloadTask?.cancel()
    personalizationUnloadTask = Task { [weak self] in
      try? await Task.sleep(for: Self.personalizationIdleUnloadDelay)
      guard !Task.isCancelled else { return }
      await self?.unloadPersonalizationModels(generation: generation)
    }
  }

  private static let personalizationIdleUnloadDelay: Duration = .seconds(30 * 60)

  private func unloadPersonalizationModels(generation: UInt64) {
    guard generation == personalizationUnloadGeneration else { return }
    ctcModels = nil
    ctcTokenizer = nil
    cachedRescorer = nil
    personalizationUnloadTask = nil
  }

  private static var personalizationModelDirectory: URL {
    CtcModels.defaultCacheDirectory(for: .ctc110m)
  }
}

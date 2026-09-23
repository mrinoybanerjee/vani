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
  private let unifiedModelDownloader: PinnedModelDownloader
  private let personalizationModelDownloader: PinnedModelDownloader
  private let unifiedModelDirectory: URL
  private var engine: Engine?
  private var unifiedIntegrityVerified = false

  /// The loaded speech engine. Unified is preferred; TDT v2 remains for installations
  /// that have not downloaded Unified yet, or if Unified cannot load on this Mac.
  private enum Engine {
    case unified(UnifiedAsrManager)
    case tdt(AsrManager, decoderLayers: Int)

    var model: SpeechModel {
      switch self {
      case .unified: .parakeetUnified
      case .tdt: .parakeetTDTv2
      }
    }
  }

  /// A base transcription from either engine.
  private struct BaseTranscript {
    let text: String
    let tokenTimings: [TokenTiming]?
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
  }
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
  private var integrityVerified = false
  private var personalizationIntegrityVerified = false

  /// Vani owns this directory so another FluidAudio app cannot add files that fail the
  /// exact-set verification, and Vani never replaces another app's model files.
  public static var defaultUnifiedModelDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vani/Models/parakeet-unified-en-0.6b-int8", isDirectory: true)
  }

  public init(unifiedModelDirectory: URL = FluidAudioSpeechRecognizer.defaultUnifiedModelDirectory)
  {
    self.unifiedModelDirectory = unifiedModelDirectory
    unifiedModelDownloader = PinnedModelDownloader(
      repository: "FluidInference/parakeet-unified-en-0.6b-coreml",
      revision: ModelIntegrityVerifier.parakeetUnifiedRevision,
      verifier: .parakeetUnified
    )
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

  /// True when either engine can run: dictation works with the fallback model while the
  /// preferred model has not been downloaded.
  public func modelsAreInstalled() async -> Bool {
    if await preferredModelIsInstalled() { return true }
    return tdtModelIsInstalled()
  }

  public func preferredModelIsInstalled() async -> Bool {
    guard FileManager.default.fileExists(atPath: unifiedModelDirectory.path) else {
      unifiedIntegrityVerified = false
      return false
    }
    if unifiedIntegrityVerified { return true }
    do {
      try ModelIntegrityVerifier.parakeetUnified.verify(directory: unifiedModelDirectory)
      unifiedIntegrityVerified = true
      return true
    } catch {
      unifiedIntegrityVerified = false
      return false
    }
  }

  public func activeModel() async -> SpeechModel? { engine?.model }

  private func tdtModelIsInstalled() -> Bool {
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

  /// Loads the preferred model when installed, otherwise the installed fallback. With
  /// neither installed (a new setup), downloads the preferred model first.
  public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    guard SystemInfo.isAppleSilicon else {
      throw VaniFailure.unsupportedHardware
    }
    if engine != nil {
      progress(1)
      return
    }
    if await preferredModelIsInstalled() {
      do {
        try await loadUnified(progress: progress)
        return
      } catch {
        // Fall back below; the preferred model stays installed for a later retry.
        VaniLog.event(category: .model, code: "unified_load_failed")
      }
    }
    if tdtModelIsInstalled() {
      try await loadTDT(progress: progress)
      return
    }
    try await installPreferredModel(progress: progress)
  }

  /// Downloads the preferred model if needed, then switches to it. The fallback engine keeps
  /// working until the switch, and stays active if the preferred model cannot load.
  public func installPreferredModel(progress: @escaping @Sendable (Double) -> Void) async throws {
    guard SystemInfo.isAppleSilicon else {
      throw VaniFailure.unsupportedHardware
    }
    if case .unified = engine {
      progress(1)
      return
    }
    do {
      if !(await preferredModelIsInstalled()) {
        try await unifiedModelDownloader.install(at: unifiedModelDirectory) { downloadProgress in
          progress(min(max(downloadProgress * 0.85, 0), 0.85))
        }
        unifiedIntegrityVerified = false
        guard await preferredModelIsInstalled() else { throw VaniFailure.modelIntegrityFailed }
      }
      try await loadUnified { value in progress(0.85 + value * 0.15) }
    } catch let failure as VaniFailure {
      throw failure
    } catch {
      throw await preferredModelIsInstalled()
        ? VaniFailure.modelLoadFailed : VaniFailure.modelDownloadFailed
    }
  }

  private func loadUnified(progress: @escaping @Sendable (Double) -> Void) async throws {
    progress(0.1)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let manager = UnifiedAsrManager(configuration: configuration, encoderPrecision: .int8)
    do {
      try await manager.loadModels(from: unifiedModelDirectory)
    } catch {
      throw VaniFailure.modelLoadFailed
    }
    engine = .unified(manager)
    progress(1)
  }

  private func loadTDT(progress: @escaping @Sendable (Double) -> Void) async throws {
    do {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      let directory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
      progress(0.65)
      let models = try await AsrModels.load(
        from: directory,
        configuration: configuration,
        version: Self.modelVersion,
        progressHandler: { download in
          progress(0.65 + min(max(download.fractionCompleted, 0), 1) * 0.35)
        }
      )
      let manager = AsrManager(config: .default, models: models)
      engine = .tdt(manager, decoderLayers: await manager.decoderLayerCount)
      progress(1)
    } catch {
      throw VaniFailure.modelLoadFailed
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

  private func transcribeBase(_ audio: CapturedAudio) async throws -> BaseTranscript {
    guard let engine else {
      throw VaniFailure.modelUnavailable
    }
    guard audio.sampleRate == CapturedAudio.targetSampleRate else {
      throw VaniFailure.audioCaptureFailed
    }
    let samples = Self.paddedForInference(audio.samples)
    do {
      switch engine {
      case .unified(let manager):
        let startedAt = Date()
        let result = try await manager.transcribeWithTimings(samples)
        let confidences = result.tokenTimings.map(\.confidence)
        return BaseTranscript(
          text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
          tokenTimings: result.tokenTimings,
          confidence: confidences.isEmpty
            ? 0 : confidences.reduce(0, +) / Float(confidences.count),
          duration: audio.duration,
          processingTime: Date().timeIntervalSince(startedAt))
      case .tdt(let manager, let decoderLayers):
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return BaseTranscript(
          text: result.text, tokenTimings: result.tokenTimings, confidence: result.confidence,
          duration: result.duration, processingTime: result.processingTime)
      }
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
    from result: BaseTranscript,
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

import CoreML
import FluidAudio
import Foundation

public actor FluidAudioSpeechRecognizer: SpeechRecognizing {
  public static let modelVersion: AsrModelVersion = .v2

  private let modelDownloader: PinnedModelDownloader
  private var manager: AsrManager?
  private var decoderLayerCount = 2
  private var integrityVerified = false

  public init() {
    modelDownloader = PinnedModelDownloader(
      repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
      revision: ModelIntegrityVerifier.parakeetV2Revision,
      verifier: .parakeetV2
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
      try ModelIntegrityVerifier.parakeetV2.verify(directory: directory)
      integrityVerified = true

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

  public func transcribe(_ audio: CapturedAudio) async throws -> SpeechResult {
    guard let manager else {
      throw VaniFailure.modelUnavailable
    }
    guard audio.sampleRate == CapturedAudio.targetSampleRate else {
      throw VaniFailure.audioCaptureFailed
    }

    do {
      var decoderState = try TdtDecoderState(decoderLayers: decoderLayerCount)
      let result = try await manager.transcribe(
        audio.samples,
        decoderState: &decoderState
      )
      return SpeechResult(
        text: result.text,
        confidence: result.confidence,
        audioDuration: result.duration,
        processingDuration: result.processingTime
      )
    } catch {
      throw VaniFailure.transcriptionFailed
    }
  }
}

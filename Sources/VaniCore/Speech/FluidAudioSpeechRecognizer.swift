import CoreML
import FluidAudio
import Foundation

public actor FluidAudioSpeechRecognizer: SpeechRecognizing {
  public static let modelVersion: AsrModelVersion = .v2

  private var manager: AsrManager?
  private var decoderLayerCount = 2

  public init() {}

  public func modelsAreInstalled() async -> Bool {
    let directory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
    return AsrModels.modelsExist(at: directory, version: Self.modelVersion)
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
      let models = try await AsrModels.downloadAndLoad(
        configuration: configuration,
        version: Self.modelVersion,
        progressHandler: { download in
          progress(min(max(download.fractionCompleted, 0), 1))
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

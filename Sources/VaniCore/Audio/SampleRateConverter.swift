import AVFoundation
import Foundation

// The buffer is immutable after init; the lock protects one-shot delivery from
// AVFoundation's Sendable input callback.
private final class AudioConverterInputState: @unchecked Sendable {
  private let lock = NSLock()
  private let inputBuffer: AVAudioPCMBuffer
  private var hasProvidedInput = false

  init(inputBuffer: AVAudioPCMBuffer) {
    self.inputBuffer = inputBuffer
  }

  func nextBuffer(
    outputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }

    guard !hasProvidedInput else {
      outputStatus.pointee = .endOfStream
      return nil
    }

    hasProvidedInput = true
    outputStatus.pointee = .haveData
    return inputBuffer
  }
}

enum SampleRateConverter {
  static func convert(
    _ samples: [Float],
    from inputSampleRate: Double,
    to outputSampleRate: Double = Double(CapturedAudio.targetSampleRate)
  ) throws -> [Float] {
    guard !samples.isEmpty else { return [] }
    guard inputSampleRate > 0, outputSampleRate > 0 else {
      throw VaniFailure.audioCaptureFailed
    }
    if abs(inputSampleRate - outputSampleRate) < 0.5 {
      return samples
    }

    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputSampleRate,
        channels: 1,
        interleaved: false
      ),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
      ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw VaniFailure.audioCaptureFailed
    }

    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(samples.count)
      )
    else {
      throw VaniFailure.audioCaptureFailed
    }
    inputBuffer.frameLength = inputBuffer.frameCapacity
    inputBuffer.floatChannelData?.pointee.update(from: samples, count: samples.count)

    let ratio = outputSampleRate / inputSampleRate
    let outputCapacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio) + 32)
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
      )
    else {
      throw VaniFailure.audioCaptureFailed
    }

    let inputState = AudioConverterInputState(inputBuffer: inputBuffer)
    let inputBlock:
      @Sendable (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>)
        -> AVAudioBuffer? = { _, outputStatus in
          inputState.nextBuffer(outputStatus: outputStatus)
        }
    var conversionError: NSError?
    let status = converter.convert(
      to: outputBuffer,
      error: &conversionError,
      withInputFrom: inputBlock
    )

    guard conversionError == nil,
      status == .haveData || status == .endOfStream || status == .inputRanDry,
      let output = outputBuffer.floatChannelData?.pointee
    else {
      throw VaniFailure.audioCaptureFailed
    }

    return Array(UnsafeBufferPointer(start: output, count: Int(outputBuffer.frameLength)))
  }
}

import AVFoundation
import Foundation

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

    var inputProvided = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) {
      _, outputStatus in
      if inputProvided {
        outputStatus.pointee = .endOfStream
        return nil
      }
      inputProvided = true
      outputStatus.pointee = .haveData
      return inputBuffer
    }

    guard conversionError == nil,
      status == .haveData || status == .endOfStream || status == .inputRanDry,
      let output = outputBuffer.floatChannelData?.pointee
    else {
      throw VaniFailure.audioCaptureFailed
    }

    return Array(UnsafeBufferPointer(start: output, count: Int(outputBuffer.frameLength)))
  }
}

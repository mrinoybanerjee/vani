import AVFoundation
import Foundation

public enum AudioFileLoader {
  public static func load(_ url: URL) throws -> CapturedAudio {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.channelCount > 0, format.sampleRate > 0,
      file.length > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    else {
      throw VaniFailure.audioCaptureFailed
    }

    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?.pointee else {
      throw VaniFailure.audioCaptureFailed
    }

    let samples = Array(
      UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    )
    let converted = try SampleRateConverter.convert(
      samples,
      from: format.sampleRate
    )
    return CapturedAudio(samples: converted)
  }
}

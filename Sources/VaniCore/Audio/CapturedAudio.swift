import Foundation

public struct CapturedAudio: Sendable, Equatable {
  public static let targetSampleRate = 16_000

  public let samples: [Float]
  public let sampleRate: Int
  public let duration: TimeInterval
  public let peakAmplitude: Float
  public let rootMeanSquare: Float

  public init(samples: [Float], sampleRate: Int = targetSampleRate) {
    self.samples = samples
    self.sampleRate = sampleRate
    duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0

    var peak: Float = 0
    var sumSquares: Double = 0
    for sample in samples {
      peak = max(peak, abs(sample))
      sumSquares += Double(sample * sample)
    }
    peakAmplitude = peak
    rootMeanSquare =
      samples.isEmpty
      ? 0
      : Float((sumSquares / Double(samples.count)).squareRoot())
  }
}

public struct AudioPolicy: Sendable, Equatable {
  public var minimumDuration: TimeInterval
  public var maximumDuration: TimeInterval
  public var minimumRootMeanSquare: Float

  public init(
    minimumDuration: TimeInterval = 0.18,
    maximumDuration: TimeInterval = 120,
    minimumRootMeanSquare: Float = 0.0015
  ) {
    self.minimumDuration = minimumDuration
    self.maximumDuration = maximumDuration
    self.minimumRootMeanSquare = minimumRootMeanSquare
  }

  public static let `default` = AudioPolicy()

  public func validate(_ audio: CapturedAudio) throws {
    guard audio.duration >= minimumDuration else {
      throw VaniFailure.recordingTooShort
    }
    guard audio.duration <= maximumDuration else {
      throw VaniFailure.recordingTooLong
    }
    guard audio.rootMeanSquare >= minimumRootMeanSquare else {
      throw VaniFailure.noSpeechDetected
    }
  }
}

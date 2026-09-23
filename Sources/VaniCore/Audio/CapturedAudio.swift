import Foundation

public struct CapturedAudio: Sendable, Equatable {
  public static let targetSampleRate = 16_000

  public let samples: [Float]
  public let sampleRate: Int
  public let duration: TimeInterval
  public let peakAmplitude: Float
  public let rootMeanSquare: Float
  /// Highest RMS of any 30 ms frame. Unlike `rootMeanSquare`, a short phrase inside
  /// a long, mostly silent recording still registers as speech-level energy.
  public let loudestFrameRootMeanSquare: Float
  public let wasTruncated: Bool

  static let loudnessFrameDuration: TimeInterval = 0.03

  public init(
    samples: [Float],
    sampleRate: Int = targetSampleRate,
    wasTruncated: Bool = false
  ) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.wasTruncated = wasTruncated
    duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0

    let frameLength = max(1, Int(Double(max(sampleRate, 1)) * Self.loudnessFrameDuration))
    var peak: Float = 0
    var sumSquares: Double = 0
    var frameSumSquares: Double = 0
    var frameCount = 0
    var loudestFrameMeanSquare: Double = 0
    for sample in samples {
      peak = max(peak, abs(sample))
      let square = Double(sample * sample)
      sumSquares += square
      frameSumSquares += square
      frameCount += 1
      if frameCount == frameLength {
        loudestFrameMeanSquare = max(loudestFrameMeanSquare, frameSumSquares / Double(frameCount))
        frameSumSquares = 0
        frameCount = 0
      }
    }
    if frameCount > 0 {
      loudestFrameMeanSquare = max(loudestFrameMeanSquare, frameSumSquares / Double(frameCount))
    }
    peakAmplitude = peak
    loudestFrameRootMeanSquare = Float(loudestFrameMeanSquare.squareRoot())
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
    maximumDuration: TimeInterval = 20 * 60,
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
    // Frame-level energy: a whole-recording average rejects a quiet phrase in a long take.
    guard audio.loudestFrameRootMeanSquare >= minimumRootMeanSquare else {
      throw VaniFailure.noSpeechDetected
    }
  }
}

import Foundation

public enum DictationCue: Sendable, Equatable {
  case started
  case stopped
}

public enum DictationCueResolver {
  public static func cue(
    previousPhase: SessionPhase,
    currentPhase: SessionPhase,
    enabled: Bool
  ) -> DictationCue? {
    guard enabled else { return nil }
    if previousPhase != .listening, currentPhase == .listening {
      return .started
    }
    if previousPhase == .listening, currentPhase != .listening {
      return .stopped
    }
    return nil
  }
}

public enum DictationCueWaveform {
  private static let sampleRate: UInt32 = 22_050

  public static func duration(for cue: DictationCue) -> Duration {
    switch cue {
    case .started: .milliseconds(65)
    case .stopped: .milliseconds(75)
    }
  }

  public static func wavData(for cue: DictationCue) -> Data {
    let parameters: (startFrequency: Double, endFrequency: Double, duration: Double) =
      switch cue {
      case .started: (620, 840, 0.065)
      case .stopped: (760, 500, 0.075)
      }
    let sampleCount = Int(Double(sampleRate) * parameters.duration)
    let fadeSampleCount = max(1, Int(Double(sampleRate) * 0.008))
    let bytesPerSample = MemoryLayout<Int16>.size
    let pcmByteCount = sampleCount * bytesPerSample

    var data = Data()
    data.reserveCapacity(44 + pcmByteCount)
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + pcmByteCount), to: &data)
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16), to: &data)
    append(UInt16(1), to: &data)
    append(UInt16(1), to: &data)
    append(sampleRate, to: &data)
    append(sampleRate * UInt32(bytesPerSample), to: &data)
    append(UInt16(bytesPerSample), to: &data)
    append(UInt16(16), to: &data)
    data.append(contentsOf: "data".utf8)
    append(UInt32(pcmByteCount), to: &data)

    var phase = 0.0
    for index in 0..<sampleCount {
      let progress = Double(index) / Double(max(1, sampleCount - 1))
      let frequency =
        parameters.startFrequency
        + (parameters.endFrequency - parameters.startFrequency) * progress
      phase += 2 * Double.pi * frequency / Double(sampleRate)
      let fadeIn = min(1, Double(index) / Double(fadeSampleCount))
      let fadeOut = min(1, Double(sampleCount - index - 1) / Double(fadeSampleCount))
      let envelope = max(0, min(fadeIn, fadeOut))
      let sample = Int16((sin(phase) * envelope * 0.10 * Double(Int16.max)).rounded())
      append(sample, to: &data)
    }
    return data
  }

  private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}

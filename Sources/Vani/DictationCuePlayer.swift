import AppKit
import VaniCore

@MainActor
final class DictationCuePlayer {
  private let startedSound = NSSound(data: DictationCueWaveform.wavData(for: .started))
  private let stoppedSound = NSSound(data: DictationCueWaveform.wavData(for: .stopped))

  init() {
    startedSound?.volume = 0.22
    stoppedSound?.volume = 0.22
  }

  func play(_ cue: DictationCue) {
    startedSound?.stop()
    stoppedSound?.stop()
    switch cue {
    case .started:
      _ = startedSound?.play()
    case .stopped:
      _ = stoppedSound?.play()
    }
  }
}

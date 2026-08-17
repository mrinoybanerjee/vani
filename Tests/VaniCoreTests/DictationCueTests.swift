import AppKit
import Foundation
import Testing

@testable import VaniCore

@Test
func dictationCuesFollowActualRecordingTransitions() {
  #expect(
    DictationCueResolver.cue(
      previousPhase: .ready,
      currentPhase: .listening,
      enabled: true
    ) == .started
  )
  #expect(
    DictationCueResolver.cue(
      previousPhase: .listening,
      currentPhase: .transcribing,
      enabled: true
    ) == .stopped
  )
  #expect(
    DictationCueResolver.cue(
      previousPhase: .listening,
      currentPhase: .recoverableError,
      enabled: true
    ) == .stopped
  )
  #expect(
    DictationCueResolver.cue(
      previousPhase: .ready,
      currentPhase: .ready,
      enabled: true
    ) == nil
  )
  #expect(
    DictationCueResolver.cue(
      previousPhase: .listening,
      currentPhase: .listening,
      enabled: true
    ) == nil
  )
  #expect(
    DictationCueResolver.cue(
      previousPhase: .ready,
      currentPhase: .listening,
      enabled: false
    ) == nil
  )
}

@Test(arguments: [DictationCue.started, .stopped])
func dictationCueWaveformsAreShortValidPCM(cue: DictationCue) {
  let data = DictationCueWaveform.wavData(for: cue)

  #expect(data.count > 44)
  #expect(data.count < 4_000)
  #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
  #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
  #expect(String(data: data[36..<40], encoding: .ascii) == "data")
  #expect(data.dropFirst(44).contains(where: { $0 != 0 }))
  #expect(NSSound(data: data) != nil)
}

@Test
func dictationCueDurationsStayShort() {
  #expect(DictationCueWaveform.duration(for: .started) == .milliseconds(65))
  #expect(DictationCueWaveform.duration(for: .stopped) == .milliseconds(75))
}

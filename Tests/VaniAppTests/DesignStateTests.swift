import AppKit
import SwiftUI
import Testing
import VaniCore

@testable import Vani

@MainActor
struct DesignStateTests {
  @Test func menuNeverClaimsReadyWhileTheShortcutIsInactive() {
    #expect(
      MenuContentState.resolve(
        phase: .ready, setupIncomplete: false, meetingOwnsSpeech: false, shortcutActive: false)
        == .shortcutInactive)
    #expect(
      MenuContentState.resolve(
        phase: .ready, setupIncomplete: false, meetingOwnsSpeech: false, shortcutActive: true)
        == .ready)
    #expect(
      MenuContentState.resolve(
        phase: .ready, setupIncomplete: true, meetingOwnsSpeech: false, shortcutActive: false)
        == .setup)
    #expect(
      MenuContentState.resolve(
        phase: .ready, setupIncomplete: false, meetingOwnsSpeech: true, shortcutActive: false)
        == .meeting)
    #expect(
      MenuContentState.resolve(
        phase: .listening, setupIncomplete: false, meetingOwnsSpeech: false, shortcutActive: true)
        == .dictating)
    #expect(
      MenuContentState.resolve(
        phase: .recoverableError, setupIncomplete: true, meetingOwnsSpeech: false,
        shortcutActive: false) == .recovery)
    #expect(
      MenuContentState.resolve(
        phase: .disabled, setupIncomplete: false, meetingOwnsSpeech: false, shortcutActive: true)
        == .setup)
  }

  @Test func setupStepsAreNumberedWithExplicitStatus() {
    let steps = SetupStepModel.steps(
      microphone: .granted, accessibility: .denied, inputMonitoring: .unknown,
      modelInstalled: false, shortcut: .function, globeKey: .showEmojiAndSymbols)
    #expect(steps.map(\.number) == [1, 2, 3, 4, 5])
    #expect(
      steps.map(\.title) == [
        "Microphone", "Accessibility", "Input Monitoring", "Speech model", "Keyboard",
      ])
    #expect(
      steps.map(\.status) == [
        "Allowed", "Not allowed", "Not requested", "Not downloaded", "Now: Show Emoji & Symbols",
      ])
    #expect(steps.map(\.actionTitle) == [nil, "Allow", "Allow", "Download", "Open"])
    #expect(steps[0].accessibilityLabel == "Step 1, Microphone, Allowed")
    #expect(steps[3].detail.contains(SpeechModel.parakeetUnified.downloadSizeDescription))
    #expect(steps[4].detail == "Set “Press 🌐 key to” → Do Nothing")

    let control = SetupStepModel.steps(
      microphone: .granted, accessibility: .granted, inputMonitoring: .granted,
      modelInstalled: true, shortcut: .leftControl, globeKey: .unknown)
    #expect(control.count == 4)
    #expect(control.allSatisfy { $0.isComplete })
    #expect(control.allSatisfy { $0.actionTitle == nil })

    let globeDone = SetupStepModel.steps(
      microphone: .granted, accessibility: .granted, inputMonitoring: .granted,
      modelInstalled: true, shortcut: .function, globeKey: .doNothing)
    #expect(globeDone.last?.isComplete == true)
    #expect(globeDone.last?.status == "Set to Do Nothing")
  }

  @Test func shortcutNamesAreMappedInTheViewLayer() {
    #expect(HoldShortcut.function.displayName == "Fn / Globe")
    #expect(HoldShortcut.function.keycapSymbol == "globe")
    #expect(HoldShortcut.leftControl.displayName == "Left Control")
    #expect(HoldShortcut.allCases.allSatisfy { !$0.keycapLabel.isEmpty })
  }

  @Test func globeKeyPreferenceValuesMap() {
    #expect(GlobeKeyAction(preferenceValue: 0) == .doNothing)
    #expect(GlobeKeyAction(preferenceValue: 1) == .changeInputSource)
    #expect(GlobeKeyAction(preferenceValue: 2) == .showEmojiAndSymbols)
    #expect(GlobeKeyAction(preferenceValue: 3) == .startDictation)
    #expect(GlobeKeyAction(preferenceValue: nil) == .unknown)
    #expect(GlobeKeyAction(preferenceValue: 9) == .unknown)
  }

  @Test func relaunchWaitsForExitThenReopensTheBundle() {
    let arguments = AppRelauncher.shellArguments(
      bundlePath: "/Applications/Vani Beta.app", processIdentifier: 4242)
    #expect(arguments.count == 3)
    #expect(arguments[0] == "-c")
    #expect(arguments[1].contains("kill -0 4242"))
    #expect(arguments[1].contains("exec /usr/bin/open \"$0\""))
    #expect(!arguments[1].contains("open -n"))
    // The path is passed as an argument, never interpolated into the script.
    #expect(!arguments[1].contains("Vani Beta"))
    #expect(arguments[2] == "/Applications/Vani Beta.app")
  }

  @Test func overlayStatesUseConsistentWordingAndSafeAnnouncements() {
    #expect(OverlayState.processing.label == "Transcribing…")
    #expect(OverlayState.processing.announcement == nil)
    #expect(OverlayState.listening.announcement == "Listening")
    #expect(OverlayState.success.announcement == "Inserted")
    #expect(OverlayState.failure("Could not insert text").announcement == "Could not insert text")
    #expect(OverlayState.hidden.announcement == nil)
  }
}

extension NativeInteractionTests {
  @Suite(.serialized) @MainActor
  struct OverlayInteractionTests {
    @Test func overlayAnnouncesStateChangesOnceAndSizesToItsTitle() {
      var announcements: [String] = []
      let overlay = OverlayController(announce: { announcements.append($0) })
      defer { overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .ready) }

      overlay.update(snapshot: SessionSnapshot(phase: .listening), previousPhase: .ready)
      overlay.update(snapshot: SessionSnapshot(phase: .listening), previousPhase: .listening)
      #expect(overlay.isVisible)
      let listeningWidth = overlay.panelSize.width
      #expect(listeningWidth >= OverlayController.minimumWidth)

      overlay.update(snapshot: SessionSnapshot(phase: .transcribing), previousPhase: .listening)
      overlay.update(
        snapshot: SessionSnapshot(phase: .ready, insertionFeedback: .verified),
        previousPhase: .inserting)
      overlay.update(
        snapshot: SessionSnapshot(
          phase: .recoverableError, failure: .inputMonitoringPermissionDenied,
          recoverableTranscript: "private words"),
        previousPhase: .transcribing)
      #expect(overlay.state == .failure("Input Monitoring access needed"))
      #expect(overlay.panelSize.width <= OverlayController.maximumWidth)
      #expect(overlay.panelSize.width > listeningWidth)

      #expect(announcements == ["Listening", "Inserted", "Input Monitoring access needed"])
      #expect(!announcements.contains { $0.contains("private words") })
    }
  }
}

@Test func improvedModelOfferStatesSizeAndLocality() {
  #expect(SpeechModel.parakeetUnified.downloadSizeDescription == "583\u{00A0}MiB")
  #expect(SpeechModel.parakeetTDTv2.downloadSizeDescription == "443\u{00A0}MiB")
}

@Test func listeningIconRestsInSilenceAndRisesWithSpeech() {
  #expect(LevelMeter.normalized(0) == 0)
  #expect(LevelMeter.normalized(.nan) == 0)
  #expect(LevelMeter.normalized(0.0005) < 0.05)  // about -66 dBFS: room noise
  #expect(LevelMeter.normalized(1) == 1)

  let silent = LevelMeter()
  let rest = silent.barHeights(level: 0, time: 12.3)
  #expect(rest.allSatisfy { $0 == LevelMeter.minimumHeight })

  let speaking = LevelMeter()
  var heights: [CGFloat] = []
  for frame in 0..<10 { heights = speaking.barHeights(level: 0.08, time: Double(frame) / 30) }
  #expect(heights.max()! > LevelMeter.minimumHeight + 4)
  #expect(heights.allSatisfy { $0 <= LevelMeter.maximumHeight })

  // Release is slower than attack: one quiet frame does not drop the bars to rest.
  let afterSpeech = speaking.barHeights(level: 0, time: 1)
  #expect(afterSpeech.max()! > LevelMeter.minimumHeight + 2)
}

@MainActor @Test func theMarkIsFiveTopAlignedBarsFormingAV() {
  let rect = CGRect(x: 0, y: 0, width: 212, height: 200)
  let bounds = VaniMark().path(in: rect).boundingRect
  #expect(abs(bounds.width - 212) < 0.5)
  #expect(abs(bounds.height - 200) < 0.5)
  #expect(VaniMark.barLengths == VaniMark.barLengths.reversed())
  #expect(VaniMark.barLengths.max() == VaniMark.barLengths[2])
  let icon = VaniMark.menuBarImage()
  #expect(icon.isTemplate)
  #expect(icon.size == NSSize(width: 18, height: 18))
}

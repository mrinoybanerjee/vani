import AppKit
import Combine
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

    @Test func overlayAnswersAPressBeforeTheSessionAndUndoesAnAbandonedStart() {
      var announcements: [String] = []
      let overlay = OverlayController(announce: { announcements.append($0) })
      defer { overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .ready) }

      let first = overlay.showStarting()
      #expect(overlay.isVisible)
      #expect(overlay.state == .listening)
      // VoiceOver hears nothing until the session confirms the recording.
      #expect(announcements.isEmpty)
      // An unrelated ready snapshot during the start does not hide it.
      overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .ready)
      #expect(overlay.state == .listening)
      overlay.update(snapshot: SessionSnapshot(phase: .listening), previousPhase: .ready)
      #expect(announcements == ["Listening"])
      // Once confirmed, the press no longer owns the pill.
      overlay.abandonStart(first)
      #expect(overlay.state == .listening)
      overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .listening)
      #expect(announcements == ["Listening", "Recording stopped"])

      // A start that never became a recording disappears without announcements, and only the
      // press that currently owns the pill can abandon it.
      let second = overlay.showStarting()
      overlay.abandonStart(first)
      #expect(overlay.state == .listening)
      overlay.abandonStart(second)
      #expect(overlay.state == .hidden)
      _ = overlay.showStarting()
      overlay.abandonStart()
      #expect(overlay.state == .hidden)

      // A refused start (a secure field) announces only the failure.
      _ = overlay.showStarting()
      overlay.update(
        snapshot: SessionSnapshot(phase: .recoverableError, failure: .secureTextField),
        previousPhase: .ready)
      #expect(
        announcements == ["Listening", "Recording stopped", VaniFailure.secureTextField.title])
    }

    @Test func handsFreeLockedDuringAStartIsAnnouncedOnlyOnceTheRecordingIsConfirmed() {
      var announcements: [String] = []
      let overlay = OverlayController(announce: { announcements.append($0) })
      defer {
        overlay.handsFree = false
        overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .ready)
      }

      _ = overlay.showStarting()
      overlay.handsFree = true
      #expect(overlay.state == .handsFree)
      #expect(announcements.isEmpty)
      overlay.update(snapshot: SessionSnapshot(phase: .listening), previousPhase: .ready)
      #expect(announcements == ["Hands-free recording locked"])
    }
  }
}

@Test func improvedModelOfferStatesSizeAndLocality() {
  #expect(SpeechModel.parakeetUnified.downloadSizeDescription == "583\u{00A0}MiB")
  #expect(SpeechModel.parakeetTDTv2.downloadSizeDescription == "443\u{00A0}MiB")
}

@Test func liveMarkWakesWithTheMicrophoneFollowsTheVoiceAndRestsAsTheMark() {
  #expect(LevelMeter.normalized(0) == 0)
  #expect(LevelMeter.normalized(.nan) == 0)
  #expect(LevelMeter.normalized(0.0005) < 0.05)  // about -66 dBFS: room noise
  #expect(LevelMeter.normalized(1) == 1)

  // Before the first audio arrives the mark is still and dimmed.
  let motion = VaniMarkMotion()
  var frame = motion.advance(activity: .listening, level: 0, time: 0)
  for step in 1...30 {
    frame = motion.advance(activity: .listening, level: 0, time: Double(step) / 60)
  }
  #expect(frame.growth.allSatisfy { $0 == 0 })
  #expect(abs(frame.opacity - VaniMarkMotion.wakingOpacity) < 0.01)

  // Room noise wakes it without moving it: silence rests as the exact mark.
  for step in 31...60 {
    frame = motion.advance(activity: .listening, level: 0.0005, time: Double(step) / 60)
  }
  #expect(frame.opacity > 0.99)
  #expect(frame.growth.allSatisfy { $0 < 1 })

  // Speech lengthens the bars below the top line, the centre leading, within bounds.
  for step in 61...90 {
    frame = motion.advance(activity: .listening, level: 0.08, time: Double(step) / 60)
  }
  #expect(frame.growth[2] > VaniMarkMotion.maximumGrowth * 0.4)
  #expect(frame.growth[2] > frame.growth[0])
  #expect(frame.growth.allSatisfy { $0 <= VaniMarkMotion.maximumGrowth })

  // Release is slower than attack: one quiet frame does not drop the bars to rest.
  let afterSpeech = motion.advance(activity: .listening, level: 0, time: 91.0 / 60)
  #expect(afterSpeech.growth[2] > VaniMarkMotion.maximumGrowth * 0.3)
}

@Test func liveMarkRipplesAcrossTheBarsWhileTranscribing() {
  let motion = VaniMarkMotion()
  var frames: [VaniMarkMotion.Frame] = []
  for step in 0..<120 {
    frames.append(motion.advance(activity: .transcribing, level: 0.5, time: Double(step) / 60))
  }
  let settled = Array(frames.suffix(60))
  let bounds = VaniMarkMotion.rippleRange
  #expect(settled.allSatisfy { $0.opacity > 0.99 })
  for frame in settled {
    #expect(
      frame.growth.allSatisfy {
        $0 <= VaniMarkMotion.maximumGrowth * bounds.upperBound + 0.5
      })
  }
  // The bars are out of step: the ripple travels rather than the mark pulsing as one.
  #expect(settled.contains { abs($0.growth[0] - $0.growth[4]) > 10 })
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

  // Growth lengthens bars below the shared top line and never moves it.
  let grown = VaniMark(growth: [0, 0, 200, 0, 0]).path(in: rect).boundingRect
  #expect(abs(grown.minY - bounds.minY) < 0.5)
  #expect(abs(grown.height - 300) < 0.5)
  #expect(VaniMark(growth: []).path(in: rect).boundingRect == bounds)
}

@MainActor @Test func menuBarKeepsTheMarkAndAnimatesOnlyWhileRecordingOrTranscribing() {
  #expect(MenuBarMark.Mode(phase: .ready) == .ready)
  #expect(MenuBarMark.Mode(phase: .setup) == .unavailable)
  #expect(MenuBarMark.Mode(phase: .preparing) == .unavailable)
  #expect(MenuBarMark.Mode(phase: .listening) == .listening)
  #expect(MenuBarMark.Mode(phase: .transcribing) == .transcribing)
  #expect(MenuBarMark.Mode(phase: .inserting) == .transcribing)
  #expect(MenuBarMark.Mode(phase: .recoverableError) == .attention)

  let mark = MenuBarMark(reduceMotion: { false })
  #expect(mark.accessibilityLabel == "Vani, not ready")
  mark.setMode(.ready)
  #expect(!mark.isAnimating)
  #expect(mark.style == .mark)
  #expect(mark.image.isTemplate)
  #expect(mark.accessibilityLabel == "Vani")

  var published = 0
  let subscription = mark.$image.dropFirst().sink { _ in published += 1 }
  defer { subscription.cancel() }
  mark.level = { 0.08 }
  mark.setMode(.listening)
  #expect(mark.isAnimating)
  #expect(mark.style == .tile)
  #expect(mark.accessibilityLabel == "Vani, listening")
  for step in 1...20 { mark.advance(at: 1_000 + Double(step) / MenuBarMark.framesPerSecond) }
  #expect(published > 5)

  // Silence settles into the still tile and stops publishing frames.
  mark.level = { 0 }
  for step in 21...80 { mark.advance(at: 1_000 + Double(step) / MenuBarMark.framesPerSecond) }
  let settled = published
  mark.advance(at: 1_000 + 81 / MenuBarMark.framesPerSecond)
  #expect(published == settled)

  mark.setMode(.transcribing)
  #expect(mark.isAnimating)
  #expect(mark.style == .tile)
  mark.setMode(.attention)
  #expect(!mark.isAnimating)
  #expect(mark.style == .badged)
  #expect(mark.accessibilityLabel == "Vani, needs attention")

  // Without motion, recording still reads differently from ready.
  let still = MenuBarMark(reduceMotion: { true })
  still.setMode(.listening)
  #expect(!still.isAnimating)
  #expect(still.style == .tile)
  #expect(still.image.isTemplate)
  still.setMode(.ready)
  #expect(still.style == .mark)
}

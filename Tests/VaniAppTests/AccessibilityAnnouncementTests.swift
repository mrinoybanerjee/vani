import Testing

@testable import Vani

@Suite struct AccessibilityAnnouncementTests {
  private typealias State = MeetingAnnouncement.State

  @Test func meetingRecordingStartAndStopAreAnnouncedOnce() {
    let idle = State(phase: .idle, summarizing: false, error: nil)
    let preparing = State(phase: .preparing, summarizing: false, error: nil)
    let recording = State(phase: .recording, summarizing: false, error: nil)
    let stopping = State(phase: .stopping, summarizing: false, error: nil)
    let transcribing = State(phase: .transcribing, summarizing: false, error: nil)
    #expect(MeetingAnnouncement.message(from: idle, to: preparing) == nil)
    #expect(
      MeetingAnnouncement.message(from: preparing, to: recording) == "Meeting recording started")
    #expect(
      MeetingAnnouncement.message(from: recording, to: stopping) == "Meeting recording stopped")
    #expect(MeetingAnnouncement.message(from: stopping, to: transcribing) == nil)
    #expect(MeetingAnnouncement.message(from: transcribing, to: idle) == nil)
    // A failed stop returns to recording; that is not a new recording.
    #expect(MeetingAnnouncement.message(from: stopping, to: recording) == nil)
  }

  @Test func interruptionsSummariesAndErrorsNameOnlyTheState() {
    let recording = State(phase: .recording, summarizing: false, error: nil)
    let interrupted = State(phase: .idle, summarizing: false, error: "Mac went to sleep.")
    #expect(
      MeetingAnnouncement.message(from: recording, to: interrupted)
        == "Meeting recording stopped. Mac went to sleep.")
    let summarizing = State(phase: .idle, summarizing: true, error: nil)
    let done = State(phase: .idle, summarizing: false, error: nil)
    let failed = State(phase: .idle, summarizing: false, error: "Ollama is not running.")
    #expect(MeetingAnnouncement.message(from: done, to: summarizing) == nil)
    #expect(MeetingAnnouncement.message(from: summarizing, to: done) == "Summary ready")
    #expect(
      MeetingAnnouncement.message(from: summarizing, to: failed)
        == "Summary not generated. Ollama is not running.")
    #expect(
      MeetingAnnouncement.message(from: done, to: failed)
        == "Meeting error: Ollama is not running.")
    #expect(MeetingAnnouncement.message(from: failed, to: failed) == nil)
  }

  @Test func downloadProgressIsAnnouncedAtQuarterMilestonesOnly() {
    #expect(ProgressMilestone.crossed(from: nil, to: 0.1) == nil)
    #expect(ProgressMilestone.crossed(from: 0.1, to: 0.26) == 25)
    #expect(ProgressMilestone.crossed(from: 0.26, to: 0.4) == nil)
    #expect(ProgressMilestone.crossed(from: 0.4, to: 0.8) == 75)
    #expect(ProgressMilestone.crossed(from: 0.8, to: 1) == 100)
    #expect(ProgressMilestone.crossed(from: 1, to: nil) == nil)
    #expect(ProgressMilestone.crossed(from: nil, to: 0.6) == 50)
  }

  @Test func overlayAnnouncesHandsFreeLockExplicitly() {
    #expect(OverlayState.handsFree.label == "Hands-free")
    #expect(OverlayState.handsFree.announcement == "Hands-free recording locked")
    #expect(OverlayState.recordingLimitWarning.announcement == "1 minute remaining")
  }
}

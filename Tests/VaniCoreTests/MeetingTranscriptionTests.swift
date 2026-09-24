import Foundation
import Testing

@testable import VaniCore

struct MeetingTranscriptionTests {
  private func segment(
    _ source: MeetingAudioSource, _ offset: TimeInterval, _ text: String, duration: Double = 20
  ) -> MeetingTranscriptSegment {
    .init(id: UUID(), source: source, offset: offset, duration: duration, text: text)
  }

  /// Adds segments in arrival order, as live transcription does.
  private func mark(_ segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
    var detector = MeetingEchoDetector()
    return segments.reduce(into: []) { transcript, segment in
      transcript = detector.adding(segment, to: transcript)
    }
  }

  private let remote =
    "Okay so the quarterly plan is mostly settled. We should ship the beta on Monday, and Priya will send the test results by Friday. After that we review the onboarding flow together."

  @Test func longMicSegmentRepeatingConcurrentMacAudioIsMarkedAsEcho() {
    let echo = segment(
      .microphone, 0.3,
      "we should ship the beta on monday and priya will send the test results by friday after that we review the onboarding flow together"
    )
    let marked = mark([segment(.system, 0, remote), echo])
    #expect(marked[1].isEcho && marked[0].echoOfSystemAudio == nil)
    // Echo marking hides text from display; it never changes or removes it.
    #expect(marked[1].text == echo.text && marked.count == 2)
  }

  @Test func echoIsDetectedWhenMacAudioArrivesAfterTheMicSegment() {
    let echo = segment(
      .microphone, 0.3,
      "the quarterly plan is mostly settled we should ship the beta on monday and priya will send the test results by friday"
    )
    var detector = MeetingEchoDetector()
    var transcript = detector.adding(echo, to: [])
    #expect(!transcript[0].isEcho)
    transcript = detector.adding(segment(.system, 0, remote), to: transcript)
    #expect(transcript[0].isEcho)
  }

  @Test func shortRepliesThatRepeatAQuestionStayVisible() {
    let cases = [
      (
        "Can you send the deck by Friday? We need it before the board meeting next week.",
        "I'll send the deck by Friday."
      ),
      (
        "So to confirm, we ship it on Tuesday, right? Unless QA finds something.",
        "Yes, ship it on Tuesday."
      ),
      (
        "I think we will cut the pricing page from this release and revisit it in May.",
        "Agreed. We will cut the pricing page."
      ),
    ]
    for (question, reply) in cases {
      let marked = mark([segment(.system, 0, question), segment(.microphone, 2, reply)])
      #expect(!marked[1].isEcho, "\(reply)")
    }
  }

  @Test func userWordsMixedWithEchoAndMisalignedChunksStayVisible() {
    // A chunk holding the user's own sentence plus 20 seconds of echo is never hidden.
    let mixed = segment(
      .microphone, 0,
      "Hang on, I disagree about the date. we should ship the beta on monday and priya will send the test results by friday"
    )
    // The same words from a Mac-audio chunk that does not overlap in time are not echo.
    let later = segment(
      .microphone, 40,
      "we should ship the beta on monday and priya will send the test results by friday")
    let marked = mark([segment(.system, 0, remote), mixed, later])
    #expect(marked.filter(\.isEcho).isEmpty)
  }

  @Test func addingSegmentsStaysFastForFourHourMeetings() {
    var detector = MeetingEchoDetector()
    var transcript: [MeetingTranscriptSegment] = []
    let start = ContinuousClock.now
    for index in 0..<(MeetingLimits.maximumSegments / 2) {
      let offset = Double(index) * 10
      transcript = detector.adding(segment(.system, offset, remote, duration: 10), to: transcript)
      transcript = detector.adding(
        segment(.microphone, offset + 0.2, "unrelated words from me number \(index) today okay"),
        to: transcript)
    }
    #expect(transcript.count == MeetingLimits.maximumSegments)
    // A guard against runaway growth in unoptimized test builds on a busy machine (4.5–7 s
    // measured). The release four-hour soak measures the real cost: about 0.2 s in total.
    #expect(ContinuousClock.now - start < .seconds(15))
  }

  @Test func vocabularyAppliesDictionaryAndOnlyEnabledPersonalization() {
    let correction = LearnedCorrection(
      spoken: "cube control", replacement: "kubectl", confirmationCount: 3)
    let vocabulary = MeetingVocabulary(
      dictionary: [DictionaryEntry(spoken: "vonnie", replacement: "Vani")],
      learnedCorrections: [correction], personalizationEnabled: true)
    #expect(
      vocabulary.process("  open vonnie and run cube control  ") == "open Vani and run kubectl")
    #expect(vocabulary.recognitionContext.personalizedTerms.map(\.canonical) == ["kubectl"])
    var disabled = vocabulary
    disabled.personalizationEnabled = false
    #expect(
      disabled.process("open vonnie and run cube control") == "open Vani and run cube control")
    #expect(disabled.recognitionContext == .empty)
    // Snippet triggers are not part of meeting vocabulary; text is never expanded.
    #expect(MeetingVocabulary.empty.process("see you soon") == "see you soon")
  }

  @Test func oldRecordsDecodeAndNewFlagsRoundTripWithoutChangingOldFields() throws {
    let id = UUID()
    let old = """
      {"id":"\(id.uuidString)","title":"Old","createdAt":0,"notes":"","summary":"",
       "transcript":[{"id":"\(UUID().uuidString)","source":"system","offset":1,"duration":2,"text":"Hi"}]}
      """
    let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(old.utf8))
    #expect(record.transcript.first?.echoOfSystemAudio == nil)
    #expect(record.transcript.first?.failed == nil)
    let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(!encoded.contains("echoOfSystemAudio") && !encoded.contains("failed"))
    var flagged = record
    flagged.transcript.append(
      .init(id: UUID(), source: .microphone, offset: 20, duration: 20, text: "", failed: true))
    #expect(
      try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(flagged)) == flagged)
  }

  @Test func exportsUseSpeakerSourcesSkipEchoAndShowFailures() {
    var meeting = MeetingRecord(title: "Weekly: plan/review")
    meeting.notes = "Ask about hiring"
    meeting.summary = "Summary\n• Hiring approved"
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 65, duration: 20, text: "Hiring is approved."),
      .init(
        id: UUID(), source: .microphone, offset: 66, duration: 20, text: "Hiring is approved.",
        echoOfSystemAudio: true),
      .init(id: UUID(), source: .microphone, offset: 40, duration: 20, text: "", failed: true),
      .init(id: UUID(), source: .microphone, offset: 10, duration: 20, text: "Thanks all."),
    ]
    let markdown = meeting.markdownText
    #expect(markdown.hasPrefix("# Weekly: plan/review\n\n## My notes\n\nAsk about hiring"))
    #expect(markdown.contains("**Me · 0:10** Thanks all."))
    #expect(markdown.contains("_Couldn’t transcribe 0:40–1:00_"))
    #expect(markdown.contains("**Others · 1:05** Hiring is approved."))
    #expect(markdown.components(separatedBy: "Hiring is approved.").count == 2)
    #expect(meeting.exportedText.contains("[0:10 · Me] Thanks all."))
    #expect(meeting.exportFileName == "Weekly- plan-review")
    meeting.title = " ../ "
    #expect(meeting.exportFileName == "-")
    meeting.title = "   "
    #expect(meeting.exportFileName == "Vani Meeting")
  }
}

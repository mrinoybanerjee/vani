import Foundation
import Testing

@testable import VaniCore

struct MeetingTranscriptionTests {
  private func segment(
    _ source: MeetingAudioSource, _ offset: TimeInterval, _ text: String, duration: Double = 20
  ) -> MeetingTranscriptSegment {
    .init(id: UUID(), source: source, offset: offset, duration: duration, text: text)
  }

  @Test func micSegmentRepeatingNearbyMacAudioIsMarkedAsEcho() {
    let remote = "We should ship the beta on Monday, and Priya will send the results by Friday."
    let echo = segment(
      .microphone, 0.4, "we should ship the beta on monday and priya will send results by friday")
    let own = segment(
      .microphone, 20, "I think Monday works for me, but let me check with legal first.")
    let marked = MeetingEchoDetector.marking([echo, own, segment(.system, 0, remote)])
    #expect(marked[0].isEcho)
    #expect(!marked[1].isEcho && marked[1].echoOfSystemAudio == nil)
    #expect(marked[2].echoOfSystemAudio == nil)
    // Echo marking hides text from display; it never changes or removes it.
    #expect(marked[0].text == echo.text && marked.count == 3)
  }

  @Test func echoIsDetectedWhenMacAudioArrivesAfterTheMicSegment() {
    let mic = segment(
      .microphone, 2, "Thanks everyone, the launch review is moved to Thursday afternoon.")
    var transcript = MeetingEchoDetector.marking([mic])
    #expect(!transcript[0].isEcho)
    transcript = MeetingEchoDetector.marking(
      transcript + [
        segment(.system, 0, "Thanks everyone. The launch review is moved to Thursday afternoon.")
      ])
    #expect(transcript[0].isEcho)
  }

  @Test func echoDetectionIsConservative() {
    let remote = segment(.system, 0, "The budget for next quarter is approved by finance today.")
    // Distant in time, mixed with the user's own speech, or too short to judge.
    let distant = segment(
      .microphone, 40, "The budget for next quarter is approved by finance today.")
    let mixed = segment(
      .microphone, 0,
      "Great news. The budget for next quarter is approved. I want to hire two engineers and plan the offsite for May."
    )
    let short = segment(.microphone, 0, "Approved today.")
    let marked = MeetingEchoDetector.marking([remote, distant, mixed, short])
    #expect(marked.filter(\.isEcho).isEmpty)
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

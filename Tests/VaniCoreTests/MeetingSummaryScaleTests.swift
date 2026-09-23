import Foundation
import Testing

@testable import VaniCore

/// Forwards each summarizer request to the real loopback Ollama and records its measured cost.
/// Test-only: the app's `LocalMeetingSummarizer()` never installs a protocol class.
final class OllamaRecorder: URLProtocol, @unchecked Sendable {
  struct Call {
    let consolidation: Bool
    let unload: Bool
    let promptCharacters: Int
    let promptTokens: Int
    let outputTokens: Int
    let doneReason: String
    let seconds: TimeInterval
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recorded: [Call] = []
  static var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
  static func reset() {
    lock.lock()
    recorded = []
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        body.append(buffer, count: count)
      }
      stream.close()
    }
    let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let consolidation = (fields["system"] as? String)?.hasPrefix("Merge numbered") == true
    let unload = fields["prompt"] == nil
    let promptCharacters =
      ((fields["system"] as? String) ?? "").count + ((fields["prompt"] as? String) ?? "").count
    var forward = URLRequest(url: request.url!)
    forward.httpMethod = request.httpMethod
    forward.httpBody = body
    forward.timeoutInterval = request.timeoutInterval
    forward.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    let started = Date()
    session.dataTask(with: forward) { [self] data, response, error in
      defer { session.finishTasksAndInvalidate() }
      guard let data, let response else {
        client?.urlProtocol(self, didFailWithError: error ?? URLError(.badServerResponse))
        return
      }
      let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      let call = Call(
        consolidation: consolidation, unload: unload, promptCharacters: promptCharacters,
        promptTokens: answer["prompt_eval_count"] as? Int ?? 0,
        outputTokens: answer["eval_count"] as? Int ?? 0,
        doneReason: answer["done_reason"] as? String ?? "",
        seconds: Date().timeIntervalSince(started))
      Self.lock.lock()
      Self.recorded.append(call)
      Self.lock.unlock()
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }.resume()
  }
}

private struct SplitMix {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A deterministic product meeting (two hours by default): twelve topics of equal length, Mac
/// audio and microphone chunks every 20 seconds, silence in some chunks, and explicit decisions
/// and actions that the summary must quote.
func syntheticTwoHourMeeting(hours: Double = 2) -> MeetingRecord {
  let topics: [(name: String, problem: String, detail: String, decision: String, action: String)] =
    [
      (
        "pricing page redesign", "the comparison table confuses people on mobile",
        "the new layout tested better with the last round of customers",
        "we ship the simplified pricing page on the fourteenth",
        "send the final copy to design"
      ),
      (
        "hiring plan", "we still have two open backend roles", "the recruiter pipeline doubled",
        "we pause the data engineer role until January", "update the job descriptions"
      ),
      (
        "API rate limits", "a few enterprise accounts keep hitting the ceiling",
        "most of the spikes come from nightly batch jobs",
        "we raise the enterprise limit to five hundred requests per minute",
        "email the affected accounts about the change"
      ),
      (
        "onboarding flow", "new users drop off at the integration step",
        "the checklist version reduced support tickets", "we keep the checklist onboarding",
        "write the help article for the checklist"
      ),
      (
        "data retention policy", "legal wants a shorter default", "most customers never change it",
        "the default retention becomes ninety days", "draft the customer notice with legal"
      ),
      (
        "mobile release", "the crash rate on older phones is still too high",
        "the fix for the image cache is in review", "we delay the mobile release by one week",
        "run the regression suite on the older devices"
      ),
      (
        "support backlog", "the queue grew over the holidays", "response time is back under a day",
        "we add a second person to weekend support", "set up the weekend rotation"
      ),
      (
        "security audit", "two findings are still open", "the auditor accepted our plan",
        "we close both findings before the end of the quarter", "book the follow-up review"
      ),
      (
        "partner integration", "the sandbox keeps timing out", "their team found the cause",
        "we launch the integration as a beta first", "share the beta invite list"
      ),
      (
        "infrastructure costs", "storage costs went up thirty percent",
        "old snapshots were never deleted", "we delete snapshots older than six months",
        "write the cleanup script"
      ),
      (
        "launch webinar", "registrations are lower than planned",
        "the new landing page just went live",
        "we move the webinar to a Thursday", "send the reminder email"
      ),
      (
        "billing migration", "invoices for annual plans look wrong",
        "the rounding bug is understood", "we migrate monthly plans first",
        "test the annual invoices in staging"
      ),
    ]
  let people = ["Priya", "Marcus", "Elena", "Tom", "Aisha", "Kenji"]
  let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  var random = SplitMix(state: 42)
  func pick<T>(_ values: [T]) -> T { values[Int(random.next() % UInt64(values.count))] }
  func sentence(_ topic: Int) -> String {
    let current = topics[topic]
    let person = pick(people)
    switch random.next() % 12 {
    case 0:
      return
        "So on the \(current.name), \(person) has been looking at the numbers and we are at about \(Int(random.next() % 90) + 10) percent of where we wanted to be."
    case 1: return "I think the main problem with the \(current.name) is that \(current.problem)."
    case 2: return "\(person), can you walk us through what changed since last week?"
    case 3: return "Yeah, so the short version is that \(current.detail)."
    case 4: return "Okay, so we agreed that \(current.decision)."
    case 5: return "\(person) will \(current.action) by \(pick(days))."
    case 6: return "I'm not sure we should commit to that yet, maybe we revisit it next week."
    case 7: return "That makes sense to me, as long as the timeline holds."
    case 8: return "Let me share my screen for a second so everyone can see the chart."
    case 9: return "Does anyone have concerns about the \(current.name) before we move on?"
    case 10: return "Right, and we should double check that with the customers who asked about it."
    default: return "Sorry, you cut out for a moment there, could you repeat the last part?"
    }
  }
  var meeting = MeetingRecord(title: "\(Int(hours))-hour planning meeting")
  let topicLength = hours * 3600 / Double(topics.count)
  for source in [MeetingAudioSource.system, .microphone] {
    for index in 0..<Int(hours * 180) {
      let offset = Double(index) * 20 + (source == .microphone ? 7 : 0)
      let topic = min(topics.count - 1, Int(offset / topicLength))
      let speaking = random.unit() < (source == .system ? 0.9 : 0.35)
      var words: [String] = []
      while speaking && words.count < (source == .system ? 45 : 20) {
        words += sentence(topic).split(separator: " ").map(String.init)
      }
      meeting.transcript.append(
        MeetingTranscriptSegment(
          id: UUID(), source: source, offset: offset, duration: 20,
          text: words.joined(separator: " ")))
    }
  }
  return meeting
}

@Suite(.serialized)
struct MeetingSummaryScaleTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["VANI_RUN_MEETING_SUMMARY_SCALE"] == "1",
      "Requires Ollama with qwen3:4b on 127.0.0.1:11434; takes several minutes"))
  func longTranscriptsStayWithinContextAndQuoteTheirSources() async throws {
    let environment = ProcessInfo.processInfo.environment
    var meetings = [("synthetic 4 h", syntheticTwoHourMeeting(hours: 4))]
    if environment["VANI_SUMMARY_SCALE_ONLY_4H"] == nil {
      meetings.insert(("synthetic 2 h", syntheticTwoHourMeeting()), at: 0)
    }
    if let path = environment["VANI_LONG_MEETING_RECORD"] {
      let record = try JSONDecoder().decode(
        MeetingRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      meetings.insert(("LibriSpeech 30 min", record), at: 0)
    }
    if let folder = environment["VANI_AMI_RECORDS"] {
      meetings.append(("AMI meetings back to back", try amiMeetingsBackToBack(in: folder)))
    }
    let summarizer = LocalMeetingSummarizer(protocolClasses: [OllamaRecorder.self])
    for (name, meeting) in meetings {
      OllamaRecorder.reset()
      let speech = meeting.transcript.filter(\.isSpeech)
      let started = Date()
      let text = try await summarizer.summarize(meeting)
      let seconds = Date().timeIntervalSince(started)
      let calls = OllamaRecorder.calls
      let generations = calls.filter { !$0.unload }
      let batches = generations.filter { !$0.consolidation }
      let merges = generations.filter(\.consolidation)
      let merge = merges.last
      let lines = text.split(separator: "\n").map(String.init)
      let quotes = lines.filter { $0.hasPrefix("  Source: “") }.map {
        String($0.dropFirst("  Source: “".count).prefix { $0 != "”" })
      }
      let transcripts = speech.map { " \(LocalMeetingSummarizer.normalized($0.text)) " }
      let unsupported = quotes.filter { quote in
        !transcripts.contains { $0.contains(" \(LocalMeetingSummarizer.normalized(quote)) ") }
      }
      var sections: [String: Int] = [:]
      var current = ""
      for line in lines {
        if ["Summary", "Decisions", "Action items"].contains(line) { current = line }
        if line.hasPrefix("• ") { sections[current, default: 0] += 1 }
      }
      print(
        "VANI_SUMMARY_SCALE \(name): \(speech.count) speech segments, "
          + "\(speech.map(\.text.count).reduce(0, +)) characters, \(String(format: "%.1f", seconds)) s, "
          + "\(batches.count) batches, consolidation "
          + (merge.map {
            "ran in \(merges.count) request(s) (last \($0.doneReason), largest "
              + "\(merges.map(\.promptTokens).max() ?? 0) prompt tokens)"
          } ?? "skipped")
          + ", items summary \(sections["Summary"] ?? 0) / decisions \(sections["Decisions"] ?? 0)"
          + " / actions \(sections["Action items"] ?? 0), \(quotes.count) quotes, "
          + "\(unsupported.count) unmatched; omitted note: "
          + (lines.last { $0.hasSuffix("omitted.") } ?? "none"))
      for call in generations {
        print(
          "VANI_SUMMARY_SCALE   \(call.consolidation ? "merge" : "batch"): "
            + "\(call.promptCharacters) characters, \(call.promptTokens) prompt + "
            + "\(call.outputTokens) output tokens, \(call.doneReason), "
            + String(format: "%.1f s", call.seconds))
        // The prompt and the largest allowed answer fit the 8,192-token context.
        #expect(call.promptTokens + LocalMeetingSummarizer.predictedTokens <= 8_192)
        #expect(call.doneReason == "stop")
      }
      #expect(unsupported.isEmpty)
      #expect(!quotes.isEmpty)
      print("VANI_SUMMARY_SCALE_TEXT \(name)\n\(text)\n")
    }
  }
}

/// The AMI records Vani transcribed, joined into one long meeting in the order given by
/// VANI_AMI_MEETINGS (or file name order), each starting where the previous one ended.
func amiMeetingsBackToBack(in folder: String) throws -> MeetingRecord {
  let directory = URL(fileURLWithPath: folder)
  let names = try FileManager.default.contentsOfDirectory(atPath: folder)
    .filter { $0.hasSuffix(".meeting.json") }.sorted()
  var combined = MeetingRecord(title: "AMI meetings back to back")
  var start: TimeInterval = 0
  for name in names {
    let record = try JSONDecoder().decode(
      MeetingRecord.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    for segment in record.transcript {
      combined.transcript.append(
        MeetingTranscriptSegment(
          id: segment.id, source: segment.source, offset: start + segment.offset,
          duration: segment.duration, text: segment.text,
          echoOfSystemAudio: segment.echoOfSystemAudio, failed: segment.failed))
    }
    start += (record.transcript.map { $0.offset + $0.duration }.max() ?? 0).rounded(.up)
  }
  return combined
}

/// Summaries of real meetings (AMI records transcribed by `AMIMeetingTests`) with the local
/// model, written for evaluation against the AMI human summaries. Opt-in: VANI_AMI_RECORDS
/// (folder of `<ID>.meeting.json`) and VANI_AMI_SUMMARY_OUTPUT. VANI_SUMMARY_MODEL selects
/// another installed Ollama model for comparison.
@Suite(.serialized)
struct AMISummaryTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["VANI_AMI_RECORDS"] != nil
        && ProcessInfo.processInfo.environment["VANI_AMI_SUMMARY_OUTPUT"] != nil,
      "Requires AMI records transcribed by Vani and Ollama on 127.0.0.1:11434"))
  func realMeetingSummariesQuoteTheirSources() async throws {
    let environment = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(environment["VANI_AMI_RECORDS"]))
    let output = URL(fileURLWithPath: try #require(environment["VANI_AMI_SUMMARY_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let model = environment["VANI_SUMMARY_MODEL"] ?? LocalMeetingSummarizer.model
    let summarizer = LocalMeetingSummarizer(protocolClasses: [OllamaRecorder.self], model: model)
    let names = try FileManager.default.contentsOfDirectory(atPath: input.path)
      .filter { $0.hasSuffix(".meeting.json") }.sorted()
    let only = environment["VANI_AMI_MEETINGS"]?.split(separator: ",").map(String.init)
    for name in names {
      let id = String(name.dropLast(".meeting.json".count))
      if let only, !only.contains(id) { continue }
      let meeting = try JSONDecoder().decode(
        MeetingRecord.self, from: Data(contentsOf: input.appendingPathComponent(name)))
      OllamaRecorder.reset()
      let started = Date()
      let text: String
      do { text = try await summarizer.summarize(meeting) } catch {
        text = "FAILED: \(error.localizedDescription)"
      }
      let seconds = Date().timeIntervalSince(started)
      let calls = OllamaRecorder.calls.filter { !$0.unload }
      let stats =
        "model \(model), \(String(format: "%.1f", seconds)) s, "
        + "\(calls.filter { !$0.consolidation }.count) batches, "
        + "\(calls.filter(\.consolidation).count) consolidation requests, largest prompt "
        + "\(calls.map(\.promptTokens).max() ?? 0) tokens, done reasons "
        + Set(calls.map(\.doneReason)).sorted().joined(separator: "/")
      try text.write(
        to: output.appendingPathComponent("\(id).summary.txt"), atomically: true, encoding: .utf8)
      try stats.write(
        to: output.appendingPathComponent("\(id).stats.txt"), atomically: true, encoding: .utf8)
      print("VANI_AMI_SUMMARY \(id): \(stats)")
      #expect(!text.hasPrefix("FAILED"))
    }
  }
}

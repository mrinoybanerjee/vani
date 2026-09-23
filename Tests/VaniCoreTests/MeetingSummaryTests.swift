import Foundation
import Testing

@testable import VaniCore

private final class MeetingSummaryProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responseData = Data()
  nonisolated(unsafe) static var status = 200
  nonisolated(unsafe) static var capturedRequest: URLRequest?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.capturedRequest = request
    let response = HTTPURLResponse(
      url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.responseData)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.serialized)
struct MeetingSummaryTests {
  private func meeting() -> MeetingRecord {
    var meeting = MeetingRecord(title: "Planning")
    meeting.transcript = [
      .init(
        id: UUID(), source: .system, offset: 20, duration: 5, text: "We agreed to launch on Monday."
      )
    ]
    return meeting
  }

  private func response(
    quote: String = "agreed to launch on Monday", segment: Int = 0, done: Bool = true
  ) throws -> Data {
    let result: [String: Any] = [
      "summary": [["text": "Launch on Monday.", "segment": segment, "quote": quote]],
      "decisions": [], "actions": [],
    ]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    return try JSONSerialization.data(withJSONObject: ["response": text, "done": done])
  }

  @Test func fixedLoopbackRequestAndQuotedSource() async throws {
    MeetingSummaryProtocol.status = 200
    MeetingSummaryProtocol.responseData = try response()
    let result = try await LocalMeetingSummarizer(protocolClasses: [MeetingSummaryProtocol.self])
      .summarize(meeting())
    #expect(result.contains("Launch on Monday. [0:20]"))
    #expect(result.contains("Source: “agreed to launch on Monday”"))
    #expect(
      MeetingSummaryProtocol.capturedRequest?.url?.absoluteString
        == "http://127.0.0.1:11434/api/generate")
    #expect(MeetingSummaryProtocol.capturedRequest?.httpMethod == "POST")
  }

  @Test func ungroundedIncompleteMalformedAndOversizedResponsesFail() async throws {
    let invalidResponses = [
      try response(quote: "Tuesday"), try response(segment: 10), try response(done: false),
      Data("not json".utf8), Data(repeating: 65, count: 262_145),
    ]
    MeetingSummaryProtocol.status = 200
    for data in invalidResponses {
      MeetingSummaryProtocol.responseData = data
      await #expect(throws: MeetingError.self) {
        try await LocalMeetingSummarizer(protocolClasses: [MeetingSummaryProtocol.self]).summarize(
          meeting())
      }
    }
    MeetingSummaryProtocol.status = 302
    MeetingSummaryProtocol.responseData = try response()
    await #expect(throws: MeetingError.self) {
      try await LocalMeetingSummarizer(protocolClasses: [MeetingSummaryProtocol.self]).summarize(
        meeting())
    }
    MeetingSummaryProtocol.status = 404
    await #expect(throws: MeetingError.self) {
      try await LocalMeetingSummarizer(protocolClasses: [MeetingSummaryProtocol.self]).summarize(
        meeting())
    }
  }
}

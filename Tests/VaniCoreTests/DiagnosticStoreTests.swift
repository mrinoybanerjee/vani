import Foundation
import Testing

@testable import VaniCore

@Test
func diagnosticStoreIsBounded() async {
  let store = DiagnosticStore(capacity: 3)

  for index in 0..<5 {
    await store.record(
      DiagnosticEvent(category: .lifecycle, code: "event-\(index)")
    )
  }

  let events = await store.snapshot()
  #expect(events.map(\.code) == ["event-2", "event-3", "event-4"])
}

@Test
func diagnosticsContainNoContentField() throws {
  let event = DiagnosticEvent(category: .transcription, code: "completed")
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
  let dictionary = try #require(object as? [String: Any])

  #expect(dictionary["text"] == nil)
  #expect(dictionary["transcript"] == nil)
  #expect(dictionary["audio"] == nil)
  #expect(dictionary["clipboard"] == nil)
}

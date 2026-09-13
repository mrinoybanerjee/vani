import Foundation
import Testing

@testable import VaniCore

struct MeetingStoreTests {
  @Test func meetingAndAudioRoundTripAndPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Project review")
    meeting.notes = "My private thoughts"
    try await store.save(meeting)
    #expect(try await store.load() == [meeting])
    let folder = try await store.audioDirectory(for: meeting.id)
    let chunk = MeetingAudioChunk(source: .system, offset: 2, samples: [0.1, -0.2, 0.3])
    let file = folder.appendingPathComponent(chunk.id.uuidString).appendingPathExtension(
      "vani-audio")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try MeetingStore.write(encoder.encode(chunk), to: file)
    let pending = try await store.pendingAudioFiles(for: meeting)
    #expect(pending.map(\.standardizedFileURL) == [file.standardizedFileURL])
    #expect(
      try await store.readAudio(#require(pending.first), meetingID: meeting.id).id == chunk.id)
    #expect(
      try await store.readAudio(file, meetingID: meeting.id).audio().samples == [0.1, -0.2, 0.3])
    meeting.transcript = [
      .init(id: chunk.id, source: .system, offset: 2, duration: 0.1, text: "Hello")
    ]
    try await store.save(meeting)
    #expect(try await store.pendingAudioFiles(for: meeting).isEmpty)
    for path in [
      file, folder.appendingPathComponent("meeting.json"),
      folder.appendingPathComponent("meeting.backup.json"),
    ] {
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    try await store.deleteAudio(for: meeting.id)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try await store.load().first?.notes == "My private thoughts")
  }

  @Test func corruptRecordAndSymlinkArePreserved() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = MeetingRecord()
    try await store.save(meeting)
    let folder = try await store.audioDirectory(for: meeting.id)
    let file = folder.appendingPathComponent("meeting.json")
    try Data("broken".utf8).write(to: file)
    await #expect(throws: (any Error).self) { try await store.save(meeting) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    await #expect(throws: (any Error).self) { try await store.load() }
    let outside = directory.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: outside)
    let link = folder.appendingPathComponent("link.vani-audio")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    await #expect(throws: (any Error).self) {
      try await store.readAudio(link, meetingID: meeting.id)
    }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
  }

  @Test func nonFiniteAudioFailsClosed() throws {
    let chunk = MeetingAudioChunk(source: .microphone, offset: 0, samples: [.nan])
    #expect(throws: MeetingError.self) { try chunk.audio() }
  }

  @Test func realLocalSummaryFixtureWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["VANI_RUN_SUMMARY_TESTS"] == "1" else { return }
    var meeting = MeetingRecord(title: "Beta planning")
    meeting.transcript = [
      .init(
        id: UUID(), source: .microphone, offset: 0, duration: 10,
        text: "Alex: We agree to launch the beta on Monday. Keep the onboarding unchanged for now."),
      .init(
        id: UUID(), source: .system, offset: 10, duration: 10,
        text:
          "Priya: I will send the test results by Friday. Alex: Thank you, that is the next action."
      ),
    ]
    let summary = try await LocalMeetingSummarizer().summarize(meeting)
    #expect(summary.localizedCaseInsensitiveContains("Monday"))
    #expect(summary.localizedCaseInsensitiveContains("Friday"))
    #expect(summary.contains("Source:"))
    if let path = ProcessInfo.processInfo.environment["VANI_SUMMARY_FIXTURE_OUTPUT"] {
      try summary.write(toFile: path, atomically: true, encoding: .utf8)
    }
  }
  @Test func emptyAbandonedDirectoryDoesNotHideSavedMeetingsButOrphanAudioFailsClosed() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = MeetingRecord(title: "Existing meeting")
    try await store.save(meeting)
    let abandoned = try await store.audioDirectory(for: UUID())
    #expect(try await store.load() == [meeting])
    try Data("orphan audio".utf8).write(to: abandoned.appendingPathComponent("orphan.vani-audio"))
    await #expect(throws: MeetingError.self) { try await store.load() }
    #expect(
      try Data(contentsOf: abandoned.appendingPathComponent("orphan.vani-audio"))
        == Data("orphan audio".utf8))
  }

  @Test func invalidTranscriptOffsetsCannotReachDisplayOrExport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord()
    meeting.transcript = [
      .init(id: UUID(), source: .system, offset: 1e30, duration: 1, text: "Unsafe time")
    ]
    await #expect(throws: MeetingError.self) { try await store.save(meeting) }
    let folder = try await store.audioDirectory(for: meeting.id)
    try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
    await #expect(throws: MeetingError.self) { try await store.load() }
  }

}

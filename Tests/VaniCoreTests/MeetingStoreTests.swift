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

  @Test func fourHourRecordsFitTheLimitsAndLongerOnesFailClosed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    #expect(MeetingLimits.maximumDuration == 14_400)
    #expect(MeetingLimits.maximumSegments == 2_880)
    var meeting = MeetingRecord(title: "Four hours")
    let text = String(repeating: "We agreed to ship the pricing page on Monday. ", count: 5)
    meeting.transcript = (0..<MeetingLimits.maximumSegments).map { index in
      .init(
        id: UUID(), source: index % 2 == 0 ? .system : .microphone,
        offset: Double(index / 2) * 10, duration: 10, text: text)
    }
    meeting.transcript[meeting.transcript.count - 1] = .init(
      id: UUID(), source: .microphone, offset: MeetingLimits.maximumDuration, duration: 4,
      text: text)
    try await store.save(meeting)
    #expect(try await MeetingStore(directory: directory).load() == [meeting])
    var tooMany = meeting
    tooMany.transcript.append(
      .init(id: UUID(), source: .system, offset: 1, duration: 1, text: "One more"))
    await #expect(throws: MeetingError.self) { try await store.save(tooMany) }
    var tooLate = meeting
    tooLate.transcript[0] = .init(
      id: UUID(), source: .system, offset: MeetingLimits.maximumDuration + 1, duration: 1,
      text: "Late")
    await #expect(throws: MeetingError.self) { try await store.save(tooLate) }
    // Chunk names and audio carry offsets up to the same bound.
    let id = UUID()
    #expect(
      MeetingAudioChunk.identity(fromFileName: "\(id.uuidString)_sys_14399500.vani-audio")?.offset
        == 14_399.5)
    #expect(
      MeetingAudioChunk.identity(fromFileName: "\(id.uuidString)_sys_14400001.vani-audio") == nil)
    let late = MeetingAudioChunk(source: .system, offset: 14_390, samples: [0.1, 0.2])
    #expect(try late.audio().samples.count == 2)
    let beyond = MeetingAudioChunk(source: .system, offset: 14_401, samples: [0.1])
    #expect(throws: MeetingError.self) { try beyond.audio() }
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

  @Test func staleTemporaryFilesFromACrashDoNotBlockLoading() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = MeetingRecord(title: "Kept")
    try await store.save(meeting)
    let saved = try await store.audioDirectory(for: meeting.id)
    try Data("partial".utf8).write(to: saved.appendingPathComponent(".\(UUID().uuidString).tmp"))
    // A crash during a first save leaves a folder holding only a temporary file.
    let crashed = try await store.audioDirectory(for: UUID())
    let leftover = crashed.appendingPathComponent(".\(UUID().uuidString).tmp")
    try Data("partial".utf8).write(to: leftover)
    #expect(try await store.load() == [meeting])
    #expect(FileManager.default.fileExists(atPath: leftover.path))
    // Leftovers older than an hour are removed when meetings load; recent ones may be in use.
    let old = saved.appendingPathComponent(".\(UUID().uuidString).tmp")
    try Data("old".utf8).write(to: old)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: leftover.path)
    #expect(try await store.load() == [meeting])
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: saved.path).filter {
        $0.hasSuffix(".tmp")
      }.count == 1)
  }

  @Test func chunkFileNamesOrderPendingAudioWithoutDecoding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = MeetingRecord()
    try await store.save(meeting)
    let folder = try await store.audioDirectory(for: meeting.id)
    let chunk = MeetingAudioChunk(source: .microphone, offset: 12.5, samples: [0.1])
    #expect(chunk.fileName == "\(chunk.id.uuidString)_mic_12500.vani-audio")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try MeetingStore.write(encoder.encode(chunk), to: folder.appendingPathComponent(chunk.fileName))
    // Damaged content still sorts by the offset in its name; foreign files are ignored.
    let damaged = UUID()
    try Data("damaged".utf8).write(
      to: folder.appendingPathComponent("\(damaged.uuidString)_sys_5000.vani-audio"))
    let foreign = folder.appendingPathComponent("notes.vani-audio")
    try Data("not a chunk".utf8).write(to: foreign)
    let pending = try await store.pendingAudioFiles(for: meeting)
    #expect(
      pending.map(\.lastPathComponent) == [
        "\(damaged.uuidString)_sys_5000.vani-audio", chunk.fileName,
      ])
    #expect(try await store.readAudio(pending[1], meetingID: meeting.id).id == chunk.id)
    // A name that disagrees with the content is rejected.
    let renamed = folder.appendingPathComponent("\(chunk.id.uuidString)_sys_12500.vani-audio")
    try FileManager.default.copyItem(at: pending[1], to: renamed)
    await #expect(throws: MeetingError.self) {
      try await store.readAudio(renamed, meetingID: meeting.id)
    }
    try FileManager.default.removeItem(at: renamed)
    for name in [
      "x.vani-audio", "\(chunk.id.uuidString)_mic_-1.vani-audio",
      "\(chunk.id.uuidString)_cam_1.vani-audio", "\(chunk.id.uuidString).txt",
    ] {
      #expect(MeetingAudioChunk.identity(fromFileName: name) == nil)
    }
    #expect(
      MeetingAudioChunk.identity(fromFileName: "\(chunk.id.uuidString).vani-audio")?.offset == nil)
    try await store.deleteAudio(for: meeting.id)
    #expect(try await store.pendingAudioFiles(for: meeting).isEmpty)
    #expect(FileManager.default.fileExists(atPath: foreign.path))
  }

  @Test func repeatedSavesKeepAValidPreviousCopyAndDetectOutsideChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "Draft")
    let folder = try await store.audioDirectory(for: meeting.id)
    let file = folder.appendingPathComponent("meeting.json")
    let backup = folder.appendingPathComponent("meeting.backup.json")
    for index in 1...3 {
      meeting.notes = "Version \(index)"
      try await store.save(meeting)
    }
    let previous = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: backup))
    #expect(previous.notes == "Version 2")
    #expect(try await store.record(id: meeting.id)?.notes == "Version 3")
    let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    // A file changed by something else is validated again instead of trusted.
    try Data("changed elsewhere".utf8).write(to: file)
    meeting.notes = "Version 4"
    await #expect(throws: (any Error).self) { try await store.save(meeting) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "changed elsewhere")
    #expect(
      try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: backup)).notes
        == "Version 2")
  }

  @Test func pendingAudioIsOrderedByOffsetAndFailurePlaceholdersAreNotPending() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord()
    try await store.save(meeting)
    let folder = try await store.audioDirectory(for: meeting.id)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    var chunks: [MeetingAudioChunk] = []
    for offset in [40.0, 0, 20] {
      let chunk = MeetingAudioChunk(source: .system, offset: offset, samples: [0.1])
      chunks.append(chunk)
      try MeetingStore.write(
        encoder.encode(chunk),
        to: folder.appendingPathComponent(chunk.id.uuidString).appendingPathExtension("vani-audio"))
    }
    try Data("unreadable".utf8).write(
      to: folder.appendingPathComponent("\(UUID().uuidString).vani-audio"))
    let names = { (files: [URL]) in files.map { $0.deletingPathExtension().lastPathComponent } }
    let pending = try await store.pendingAudioFiles(for: meeting)
    #expect(
      Array(names(pending).prefix(3)) == [chunks[1], chunks[2], chunks[0]].map(\.id.uuidString))
    #expect(pending.count == 4)
    meeting.transcript = [
      .init(id: chunks[1].id, source: .system, offset: 0, duration: 1, text: "", failed: true)
    ]
    #expect(
      !names(try await store.pendingAudioFiles(for: meeting)).contains(chunks[1].id.uuidString))
    #expect(try await store.pendingAudioFiles(for: meeting).count == 3)
  }

  @Test func onlyAnUnusedMeetingCanBeDiscarded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let unused = MeetingRecord(title: "Never started")
    try await store.save(unused)
    try await store.discardUnused(unused.id)
    #expect(try await store.load().isEmpty)
    var noted = MeetingRecord(title: "Has notes")
    noted.notes = "Keep me"
    try await store.save(noted)
    await #expect(throws: MeetingError.self) { try await store.discardUnused(noted.id) }
    let withAudio = MeetingRecord(title: "Has audio")
    try await store.save(withAudio)
    let folder = try await store.audioDirectory(for: withAudio.id)
    try Data("audio".utf8).write(to: folder.appendingPathComponent("chunk.vani-audio"))
    await #expect(throws: MeetingError.self) { try await store.discardUnused(withAudio.id) }
    #expect(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("chunk.vani-audio").path)
    )
    #expect(try await store.record(id: noted.id)?.notes == "Keep me")
  }

}

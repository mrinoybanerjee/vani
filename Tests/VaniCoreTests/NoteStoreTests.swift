import Foundation
import Testing

@testable import VaniCore

private struct NotesDocumentFixture: Codable {
  var version = 1
  var notes: [VaniNote]
}

private struct NotesFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vani-note-tests-\(UUID())", isDirectory: true)
  var current: URL { directory.appendingPathComponent("notes.json") }
  var backup: URL { directory.appendingPathComponent("notes.backup.json") }

  func cleanup() { try? FileManager.default.removeItem(at: directory) }

  func write(_ notes: [VaniNote], version: Int = 1) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(NotesDocumentFixture(version: version, notes: notes))
      .write(to: current)
  }

  func mode(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
      .intValue
  }
}

@Suite(.serialized)
struct NoteStoreTests {
  @Test
  func createEditAndReopenPreserveIdentityAndPreviousCopy() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    #expect(try await store.load().isEmpty)
    let original = VaniNote(
      title: "Research", text: "First thought 🌱", now: Date(timeIntervalSince1970: 100))
    #expect(try await store.save(original) == [original])
    var edited = original
    edited.title = "Research notes"
    edited.text = "Updated thought\nSecond line"
    edited.updatedAt = Date(timeIntervalSince1970: 200)
    #expect(try await store.save(edited) == [edited])

    let reopened = NoteStore(directory: fixture.directory)
    #expect(try await reopened.load() == [edited])
    let backup = try JSONDecoder().decode(
      NotesDocumentFixture.self, from: Data(contentsOf: fixture.backup))
    #expect(backup.notes == [original])
    #expect(try fixture.mode(fixture.directory) == 0o700)
    #expect(try fixture.mode(fixture.current) == 0o600)
    #expect(try fixture.mode(fixture.backup) == 0o600)
    #expect(
      try !FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains {
        $0.hasSuffix(".tmp")
      })
  }

  @Test
  func softDeleteAndRestorePreserveNoteContentsAcrossReopen() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    var note = VaniNote(title: "Keep", text: "Do not lose this")
    _ = try await store.save(note)
    note.deletedAt = Date(timeIntervalSince1970: 500)
    _ = try await store.save(note)
    #expect(try await NoteStore(directory: fixture.directory).load() == [note])
    note.deletedAt = nil
    _ = try await store.save(note)
    #expect(try await NoteStore(directory: fixture.directory).load() == [note])
  }

  @Test
  func concurrentSavesOnTheSharedStoreDoNotLoseNotes() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    let notes = (0..<25).map { VaniNote(title: "Note \($0)", text: "Text \($0)") }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for note in notes {
        group.addTask { _ = try await store.save(note) }
      }
      try await group.waitForAll()
    }
    let loaded = try await store.load()
    #expect(Set(loaded.map(\.id)) == Set(notes.map(\.id)))
    #expect(loaded.count == notes.count)
  }

  @Test
  func corruptionBlocksWritesWithoutReplacingCurrentOrBackup() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    _ = try await store.save(VaniNote(text: "First"))
    _ = try await store.save(VaniNote(text: "Second"))
    let backup = try Data(contentsOf: fixture.backup)
    let corrupted = Data("incomplete json {".utf8)
    try corrupted.write(to: fixture.current)

    await #expect(throws: NoteStoreError.self) { try await store.load() }
    await #expect(throws: NoteStoreError.self) {
      try await store.save(VaniNote(text: "Must not replace"))
    }
    #expect(try Data(contentsOf: fixture.current) == corrupted)
    #expect(try Data(contentsOf: fixture.backup) == backup)
  }

  @Test
  func restoringBackupPreservesTheCorruptedCurrentFile() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    let original = VaniNote(text: "Recover this")
    _ = try await store.save(original)
    _ = try await store.save(VaniNote(text: "Second"))
    let backup = try Data(contentsOf: fixture.backup)
    let corrupted = Data("not-json".utf8)
    try corrupted.write(to: fixture.current)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.current.path)

    #expect(try await store.restoreBackup() == [original])
    #expect(try await NoteStore(directory: fixture.directory).load() == [original])
    #expect(try Data(contentsOf: fixture.backup) == backup)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("notes.preserved-") }
    #expect(preserved.count == 1)
    let preservedFile = try #require(preserved.first)
    #expect(try Data(contentsOf: preservedFile) == corrupted)
    #expect(try fixture.mode(preservedFile) == 0o600)
  }

  @Test
  func invalidBackupCannotReplaceTheCurrentFile() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    _ = try await store.save(VaniNote(text: "Current"))
    let current = try Data(contentsOf: fixture.current)
    try Data("bad backup".utf8).write(to: fixture.backup)
    await #expect(throws: NoteStoreError.self) { try await store.restoreBackup() }
    #expect(try Data(contentsOf: fixture.current) == current)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == [
        "notes.backup.json", "notes.json",
      ])
  }

  @Test
  func writesKeepExistingFilesPrivate() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    var note = VaniNote(text: "Original")
    _ = try await store.save(note)
    note.text = "Second"
    _ = try await store.save(note)
    for file in [fixture.current, fixture.backup] {
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    note.text = "Third"
    _ = try await store.save(note)
    #expect(try fixture.mode(fixture.current) == 0o600)
    #expect(try fixture.mode(fixture.backup) == 0o600)
  }

  @Test
  func perNoteBoundsUseBytesAndRejectWithoutChangingSavedData() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    var note = VaniNote(
      title: String(repeating: "é", count: 2_048),
      text: String(repeating: "x", count: 1_024 * 1_024))
    _ = try await store.save(note)
    let original = try Data(contentsOf: fixture.current)
    note.text += "x"
    await #expect(throws: NoteStoreError.self) { try await store.save(note) }
    #expect(try Data(contentsOf: fixture.current) == original)
    note.text = "Small"
    note.title += "é"
    await #expect(throws: NoteStoreError.self) { try await store.save(note) }
    #expect(try Data(contentsOf: fixture.current) == original)
  }

  @Test
  func noteCountLimitAllowsEditingButRejectsAdditionalNotes() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    var notes = (0..<1_000).map { VaniNote(text: "Note \($0)") }
    try fixture.write(notes)
    let store = NoteStore(directory: fixture.directory)
    notes[0].text = "Updated without adding a note"
    #expect(try await store.save(notes[0]).count == 1_000)
    let original = try Data(contentsOf: fixture.current)
    await #expect(throws: NoteStoreError.self) {
      try await store.save(VaniNote(text: "One too many"))
    }
    #expect(try Data(contentsOf: fixture.current) == original)
  }

  @Test
  func totalEncodedSizeLimitRejectsWithoutReplacingSavedData() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let text = String(repeating: "x", count: 1_024 * 1_024)
    try fixture.write((0..<15).map { VaniNote(title: "Note \($0)", text: text) })
    let original = try Data(contentsOf: fixture.current)
    let store = NoteStore(directory: fixture.directory)
    await #expect(throws: NoteStoreError.self) { try await store.save(VaniNote(text: text)) }
    #expect(try Data(contentsOf: fixture.current) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
  }

  @Test
  func oversizedInputFileIsRejectedWithoutMutation() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    try fixture.write([])
    let handle = try FileHandle(forWritingTo: fixture.current)
    try handle.truncate(atOffset: 16 * 1_024 * 1_024 + 1)
    try handle.close()
    let store = NoteStore(directory: fixture.directory)
    await #expect(throws: NoteStoreError.self) { try await store.load() }
    #expect(
      try fixture.current.resourceValues(forKeys: [.fileSizeKey]).fileSize == 16 * 1_024 * 1_024 + 1
    )
  }

  @Test(arguments: [false, true])
  func invalidDocumentIdentityOrVersionIsRejected(duplicateIDs: Bool) async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let note = VaniNote(text: "Preserve malformed data")
    try fixture.write(duplicateIDs ? [note, note] : [note], version: duplicateIDs ? 1 : 2)
    let original = try Data(contentsOf: fixture.current)
    let store = NoteStore(directory: fixture.directory)
    await #expect(throws: NoteStoreError.self) { try await store.load() }
    await #expect(throws: NoteStoreError.self) {
      try await store.save(VaniNote(text: "No overwrite"))
    }
    #expect(try Data(contentsOf: fixture.current) == original)
  }

  @Test(arguments: ["notes.json", "notes.backup.json"])
  func symlinkedDataFilesNeverTouchTheirTargets(name: String) async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    _ = try await store.save(VaniNote(text: "Existing"))
    let target = fixture.directory.appendingPathComponent("unrelated.txt")
    let original = Data("private unrelated file".utf8)
    try original.write(to: target)
    let link = fixture.directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: link.path) {
      try FileManager.default.removeItem(at: link)
    }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    do {
      _ = try await store.save(VaniNote(text: "Rejected"))
      Issue.record("Saving through a symlink must fail")
    } catch NoteStoreError.unsafeLocation {
      // Reject the link before attempting to decode its target.
    } catch {
      Issue.record("Expected unsafeLocation, got \(error)")
    }
    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
  }

  @Test
  func missingCurrentFileWithBackupRequiresExplicitRecovery() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    let store = NoteStore(directory: fixture.directory)
    let original = VaniNote(text: "Recover me")
    _ = try await store.save(original)
    _ = try await store.save(VaniNote(text: "Second"))
    try FileManager.default.removeItem(at: fixture.current)
    await #expect(throws: NoteStoreError.self) { try await store.load() }
    await #expect(throws: NoteStoreError.self) {
      try await store.save(VaniNote(text: "No silent reset"))
    }
    #expect(try await store.restoreBackup() == [original])
    #expect(try await store.load() == [original])
  }

  @Test
  func symlinkedDirectoryIsRejected() async throws {
    let fixture = NotesFixture()
    defer { fixture.cleanup() }
    try fixture.write([])
    let link = fixture.directory.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
    let original = try Data(contentsOf: fixture.current)
    let store = NoteStore(directory: link)
    await #expect(throws: NoteStoreError.self) { try await store.load() }
    #expect(try Data(contentsOf: fixture.current) == original)
  }
}

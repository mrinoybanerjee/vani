import Foundation

public struct VaniNote: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var text: String
  public let createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(title: String = "", text: String = "", now: Date = Date()) {
    id = UUID()
    self.title = title
    self.text = text
    createdAt = now
    updatedAt = now
  }

  public var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled note" : trimmed
  }

  public var exportedText: String { "\(displayTitle)\n\n\(text)\n" }
}

public enum NoteStoreError: LocalizedError {
  case invalidFile, limitExceeded, unsafeLocation

  public var errorDescription: String? {
    switch self {
    case .invalidFile:
      "Notes could not be read. Your files have been preserved. You can restore the previous saved copy."
    case .limitExceeded:
      "Notes exceed the storage limit (1,000 notes, 1 MiB per note, 16 MiB total). Export notes to keep a separate copy."
    case .unsafeLocation: "The Notes location is not a regular local file or directory."
    }
  }
}

/// A separate, lazy local store. No dictation or history operations depend on it.
public actor NoteStore {
  private struct Document: Codable {
    var version = 1
    var notes: [VaniNote]
  }

  private let directory: URL
  private var file: URL { directory.appendingPathComponent("notes.json") }
  private var backup: URL { directory.appendingPathComponent("notes.backup.json") }
  private let maximumBytes = 16 * 1_024 * 1_024

  public init(
    directory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Vani/Notes", isDirectory: true)
  ) {
    self.directory = directory
  }

  public func load() throws -> [VaniNote] {
    try prepareDirectory()
    guard FileManager.default.fileExists(atPath: file.path) else {
      guard !FileManager.default.fileExists(atPath: backup.path) else {
        throw NoteStoreError.invalidFile
      }
      return []
    }
    return try decode(file)
  }

  public func save(_ note: VaniNote) throws -> [VaniNote] {
    var notes = try load()
    if let index = notes.firstIndex(where: { $0.id == note.id }) {
      notes[index] = note
    } else {
      notes.append(note)
    }
    try validate(notes)
    let data = try JSONEncoder().encode(Document(notes: notes))
    guard data.count <= maximumBytes else { throw NoteStoreError.limitExceeded }
    if FileManager.default.fileExists(atPath: file.path) {
      try write(try Data(contentsOf: file), to: backup)
    }
    try write(data, to: file)
    return notes
  }

  public func restoreBackup() throws -> [VaniNote] {
    try prepareDirectory()
    let notes = try decode(backup)
    let data = try JSONEncoder().encode(Document(notes: notes))
    if FileManager.default.fileExists(atPath: file.path) {
      try checkRegularFile(file)
      // Preserve the current file before explicitly replacing it with the backup.
      let preserved = directory.appendingPathComponent("notes.preserved-\(UUID()).json")
      try FileManager.default.copyItem(at: file, to: preserved)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: preserved.path)
    }
    try write(data, to: file)
    return notes
  }

  private func decode(_ url: URL) throws -> [VaniNote] {
    try checkRegularFile(url)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes + 1
    guard size <= maximumBytes else { throw NoteStoreError.limitExceeded }
    let document: Document
    do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)) } catch {
      throw NoteStoreError.invalidFile
    }
    guard document.version == 1 else { throw NoteStoreError.invalidFile }
    try validate(document.notes)
    return document.notes
  }

  private func validate(_ notes: [VaniNote]) throws {
    guard notes.count <= 1_000,
      notes.allSatisfy({ $0.text.utf8.count <= 1_024 * 1_024 && $0.title.utf8.count <= 4_096 })
    else { throw NoteStoreError.limitExceeded }
    guard Set(notes.map(\.id)).count == notes.count else { throw NoteStoreError.invalidFile }
  }

  private func prepareDirectory() throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw NoteStoreError.unsafeLocation
      }
    } else {
      try fm.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func checkRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw NoteStoreError.unsafeLocation
    }
  }

  private func write(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) { try checkRegularFile(url) }
    let temporary = directory.appendingPathComponent(".\(UUID()).tmp")
    defer { try? fm.removeItem(at: temporary) }
    guard
      fm.createFile(
        atPath: temporary.path, contents: data,
        attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
    } else {
      try fm.moveItem(at: temporary, to: url)
    }
  }
}

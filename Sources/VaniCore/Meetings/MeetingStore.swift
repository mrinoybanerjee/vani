import Foundation

public actor MeetingStore {
  public let directory: URL
  public static let maximumRecordBytes = 8 * 1_024 * 1_024

  /// The record this actor last wrote. While the file on disk still matches it, that record can
  /// become the backup without being read and decoded again.
  private struct Written {
    let id: UUID
    let data: Data
    let fingerprint: Fingerprint
  }
  private struct Fingerprint: Equatable {
    let fileNumber: Int
    let size: Int
    let modified: Date
  }
  private var lastWritten: Written?
  /// Chunk files are write-once, so their offsets can be remembered after one read.
  private var chunkOffsets: [String: TimeInterval] = [:]

  public init(directory: URL? = nil) {
    self.directory =
      (directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vani/Meetings", isDirectory: true)).standardizedFileURL
  }

  public func load() throws -> [MeetingRecord] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    try Self.validateDirectory(directory)
    let folders = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    var records: [MeetingRecord] = []
    for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
      if let record = try Self.readRecord(in: folder) { records.append(record) }
    }
    return records.sorted { $0.createdAt > $1.createdAt }
  }

  /// The latest stored copy of one meeting, or nil when it has not been saved.
  public func record(id: UUID) throws -> MeetingRecord? {
    let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
    try Self.validateDirectory(directory)
    return try Self.readRecord(in: folder)
  }

  public func save(_ meeting: MeetingRecord) throws {
    try Self.validate(meeting)
    let data = try JSONEncoder().encode(meeting)
    guard data.count <= Self.maximumRecordBytes else { throw MeetingError.invalidData }
    let folder = try folder(for: meeting.id)
    let file = folder.appendingPathComponent("meeting.json")
    let backup = folder.appendingPathComponent("meeting.backup.json")
    if FileManager.default.fileExists(atPath: file.path) {
      if let lastWritten, lastWritten.id == meeting.id,
        try Self.fingerprint(of: file) == lastWritten.fingerprint
      {
        try Self.write(lastWritten.data, to: backup)
      } else {
        let previous = try Self.read(file, limit: Self.maximumRecordBytes)
        let record = try JSONDecoder().decode(MeetingRecord.self, from: previous)
        guard record.id == meeting.id else { throw MeetingError.invalidData }
        try Self.validate(record)
        try Self.write(previous, to: backup)
      }
    } else if FileManager.default.fileExists(atPath: backup.path) {
      throw MeetingError.invalidData
    }
    lastWritten = nil
    try Self.write(data, to: file)
    lastWritten = (try? Self.fingerprint(of: file)).map {
      Written(id: meeting.id, data: data, fingerprint: $0)
    }
  }

  /// Removes a meeting that was created but never received audio, notes, transcript or summary.
  /// Anything else in its folder is preserved and the call fails closed.
  public func discardUnused(_ id: UUID) throws {
    let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    guard let record = try Self.readRecord(in: folder), record.notes.isEmpty,
      record.transcript.isEmpty, record.summary.isEmpty
    else { throw MeetingError.invalidData }
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    guard names.isSubset(of: ["meeting.json", "meeting.backup.json"]) else {
      throw MeetingError.invalidData
    }
    if lastWritten?.id == id { lastWritten = nil }
    try FileManager.default.removeItem(at: folder)
  }

  public func audioDirectory(for id: UUID) throws -> URL { try folder(for: id) }

  /// Saved audio without a transcript segment (failure placeholders count as segments), in
  /// recording order: offset, then ID. Unreadable chunks sort last, so they cannot hold back
  /// the rest of the meeting.
  public func pendingAudioFiles(for meeting: MeetingRecord) throws -> [URL] {
    let folder = try folder(for: meeting.id)
    let completed = Set(meeting.transcript.map { $0.id.uuidString })
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "vani-audio" }
    guard files.count <= 1440 else { throw MeetingError.invalidData }
    let pending = files.filter { !completed.contains($0.deletingPathExtension().lastPathComponent) }
    var offsets: [String: TimeInterval] = [:]
    for file in pending {
      offsets[file.lastPathComponent] = chunkOffset(file, meetingID: meeting.id)
    }
    return pending.sorted {
      let left = offsets[$0.lastPathComponent] ?? .infinity
      let right = offsets[$1.lastPathComponent] ?? .infinity
      return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
    }
  }

  private func chunkOffset(_ file: URL, meetingID: UUID) -> TimeInterval {
    let key = file.standardizedFileURL.path
    if let offset = chunkOffsets[key] { return offset }
    guard let offset = try? readAudio(file, meetingID: meetingID).offset else { return .infinity }
    chunkOffsets[key] = offset
    return offset
  }

  public func readAudio(_ file: URL, meetingID: UUID) throws -> MeetingAudioChunk {
    guard
      file.deletingLastPathComponent().standardizedFileURL
        == directory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        .standardizedFileURL
    else {
      throw MeetingError.invalidData
    }
    let chunk = try PropertyListDecoder().decode(
      MeetingAudioChunk.self, from: Self.read(file, limit: 2_000_000))
    guard chunk.id.uuidString == file.deletingPathExtension().lastPathComponent else {
      throw MeetingError.invalidData
    }
    return chunk
  }

  public func deleteAudio(for id: UUID) throws {
    let folder = try folder(for: id)
    for file in try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    where file.pathExtension == "vani-audio" {
      try Self.validateRegularFile(file, limit: 2_000_000)
      try FileManager.default.removeItem(at: file)
      chunkOffsets[file.standardizedFileURL.path] = nil
    }
  }

  private func folder(for id: UUID) throws -> URL {
    try Self.createPrivateDirectory(directory)
    let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    try Self.createPrivateDirectory(folder)
    return folder
  }

  /// Nil for an abandoned folder that never received a record.
  private static func readRecord(in folder: URL) throws -> MeetingRecord? {
    try validateDirectory(folder)
    let file = folder.appendingPathComponent("meeting.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
      // A crash during the first atomic write leaves only a hidden temporary file, which never
      // became a record. It is ignored, not deleted: a live capture may be writing beside it.
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      if names.allSatisfy(isTemporaryFileName) { return nil }
      throw MeetingError.invalidData
    }
    let record = try JSONDecoder().decode(
      MeetingRecord.self, from: read(file, limit: maximumRecordBytes))
    guard record.id.uuidString == folder.lastPathComponent else { throw MeetingError.invalidData }
    try validate(record)
    return record
  }

  static func isTemporaryFileName(_ name: String) -> Bool {
    name.hasPrefix(".") && name.hasSuffix(".tmp")
  }

  static func validate(_ meeting: MeetingRecord) throws {
    guard meeting.title.utf8.count <= 4096, meeting.notes.utf8.count <= 1_048_576,
      meeting.summary.utf8.count <= 1_048_576, meeting.transcript.count <= 1440,
      Set(meeting.transcript.map(\.id)).count == meeting.transcript.count,
      meeting.createdAt.timeIntervalSince1970.isFinite,
      meeting.endedAt?.timeIntervalSince1970.isFinite != false,
      meeting.deletedAt?.timeIntervalSince1970.isFinite != false,
      meeting.transcript.allSatisfy({
        $0.offset.isFinite && $0.offset >= 0 && $0.offset <= 7200
          && $0.duration.isFinite && $0.duration >= 0 && $0.duration <= 25
          && $0.text.utf8.count <= 48_000
      })
    else { throw MeetingError.invalidData }
  }

  static func createPrivateDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try validateDirectory(url)
    } else {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
  }

  static func validateDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MeetingError.invalidData
    }
  }

  static func validateRegularFile(_ url: URL, limit: Int) throws {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= limit
    else { throw MeetingError.invalidData }
  }

  static func read(_ url: URL, limit: Int) throws -> Data {
    try validateRegularFile(url, limit: limit)
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw MeetingError.invalidData }
    return data
  }

  private static func fingerprint(of url: URL) throws -> Fingerprint {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
      let size = (attributes[.size] as? NSNumber)?.intValue,
      let modified = attributes[.modificationDate] as? Date
    else { throw MeetingError.invalidData }
    return Fingerprint(fileNumber: number, size: size, modified: modified)
  }

  static func write(_ data: Data, to url: URL) throws {
    let fileManager = FileManager.default
    try validateDirectory(url.deletingLastPathComponent())
    if fileManager.fileExists(atPath: url.path) {
      try validateRegularFile(url, limit: maximumRecordBytes)
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).tmp")
    guard
      fileManager.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      throw MeetingError.storage(
        "The meeting could not be saved. Free some disk space and try again.")
    }
    defer { try? fileManager.removeItem(at: temporary) }
    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
    } else {
      try fileManager.moveItem(at: temporary, to: url)
    }
  }
}

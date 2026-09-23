import Foundation

public actor MeetingStore {
  public let directory: URL
  public static let maximumRecordBytes = 8 * 1_024 * 1_024

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
      try Self.validateDirectory(folder)
      let file = folder.appendingPathComponent("meeting.json")
      guard FileManager.default.fileExists(atPath: file.path) else {
        if try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty { continue }
        throw MeetingError.invalidData
      }
      let record = try JSONDecoder().decode(
        MeetingRecord.self, from: Self.read(file, limit: Self.maximumRecordBytes))
      guard record.id.uuidString == folder.lastPathComponent else { throw MeetingError.invalidData }
      try Self.validate(record)
      records.append(record)
    }
    return records.sorted { $0.createdAt > $1.createdAt }
  }

  public func save(_ meeting: MeetingRecord) throws {
    try Self.validate(meeting)
    let data = try JSONEncoder().encode(meeting)
    guard data.count <= Self.maximumRecordBytes else { throw MeetingError.invalidData }
    let folder = try folder(for: meeting.id)
    let file = folder.appendingPathComponent("meeting.json")
    let backup = folder.appendingPathComponent("meeting.backup.json")
    if FileManager.default.fileExists(atPath: file.path) {
      let previous = try Self.read(file, limit: Self.maximumRecordBytes)
      let record = try JSONDecoder().decode(MeetingRecord.self, from: previous)
      guard record.id == meeting.id else { throw MeetingError.invalidData }
      try Self.validate(record)
      try Self.write(previous, to: backup)
    } else if FileManager.default.fileExists(atPath: backup.path) {
      throw MeetingError.invalidData
    }
    try Self.write(data, to: file)
  }

  public func audioDirectory(for id: UUID) throws -> URL { try folder(for: id) }

  public func pendingAudioFiles(for meeting: MeetingRecord) throws -> [URL] {
    let folder = try folder(for: meeting.id)
    let completed = Set(meeting.transcript.map { $0.id.uuidString })
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
    )
    .filter { $0.pathExtension == "vani-audio" }
    guard files.count <= 1440 else { throw MeetingError.invalidData }
    return files.filter { !completed.contains($0.deletingPathExtension().lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
      _ = try Self.read(file, limit: 2_000_000)
      try FileManager.default.removeItem(at: file)
    }
  }

  private func folder(for id: UUID) throws -> URL {
    try Self.createPrivateDirectory(directory)
    let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    try Self.createPrivateDirectory(folder)
    return folder
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

  static func read(_ url: URL, limit: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= limit
    else { throw MeetingError.invalidData }
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw MeetingError.invalidData }
    return data
  }

  static func write(_ data: Data, to url: URL) throws {
    let fileManager = FileManager.default
    try validateDirectory(url.deletingLastPathComponent())
    if fileManager.fileExists(atPath: url.path) { _ = try read(url, limit: maximumRecordBytes) }
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

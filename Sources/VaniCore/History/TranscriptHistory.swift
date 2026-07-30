import Foundation

private enum TranscriptHistoryStoreError: Error {
  case fileTooLarge
}

public struct TranscriptHistoryEntry: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let createdAt: Date
  public let text: String

  public init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
    self.id = id
    self.createdAt = createdAt
    self.text = text
  }
}

public actor TranscriptHistoryStore {
  private static let historyFileName = "history.json"
  private static let quarantinePrefix = "history.corrupt-"
  private static let quarantineSuffix = ".json"
  static let maximumHistoryFileBytes = 64 * 1_024 * 1_024

  private let fileManager: FileManager
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    directory: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    let baseDirectory =
      directory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vani", isDirectory: true)
    fileURL = baseDirectory.appendingPathComponent(Self.historyFileName)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  public func load() throws -> [TranscriptHistoryEntry] {
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let values = try fileURL.resourceValues(forKeys: [
        .fileSizeKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize <= Self.maximumHistoryFileBytes
      else {
        throw VaniFailure.historyCorrupt
      }
      let data = try Data(contentsOf: fileURL)
      return try decoder.decode([TranscriptHistoryEntry].self, from: data)
    } catch {
      try quarantineCorruptFile()
      throw VaniFailure.historyCorrupt
    }
  }

  public func append(_ entry: TranscriptHistoryEntry, limit: Int) throws {
    var entries: [TranscriptHistoryEntry]
    do {
      entries = try load()
    } catch VaniFailure.historyCorrupt {
      entries = []
    }
    entries.insert(entry, at: 0)
    entries = Array(entries.prefix(min(max(limit, 10), 500)))
    try write(entries)
  }

  public func clear() throws {
    for storedURL in try storedDataURLs() {
      try fileManager.removeItem(at: storedURL)
    }
  }

  public func hasStoredData() throws -> Bool {
    try !storedDataURLs().isEmpty
  }

  private func write(_ entries: [TranscriptHistoryEntry]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let data = try encoder.encode(entries)
    guard data.count <= Self.maximumHistoryFileBytes else {
      throw TranscriptHistoryStoreError.fileTooLarge
    }
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func quarantineCorruptFile() throws {
    let stamp = Int(Date().timeIntervalSince1970)
    let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      "\(Self.quarantinePrefix)\(stamp)-\(UUID().uuidString)\(Self.quarantineSuffix)"
    )
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.moveItem(at: fileURL, to: quarantineURL)
    }
  }

  private func storedDataURLs() throws -> [URL] {
    let directory = fileURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ).filter { url in
      let name = url.lastPathComponent
      guard
        name == Self.historyFileName
          || (name.hasPrefix(Self.quarantinePrefix) && name.hasSuffix(Self.quarantineSuffix)),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
        ])
      else {
        return false
      }
      return values.isRegularFile == true || values.isSymbolicLink == true
    }
  }
}

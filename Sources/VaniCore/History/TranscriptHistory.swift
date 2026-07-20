import Foundation

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
    fileURL = baseDirectory.appendingPathComponent("history.json")

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
      let data = try Data(contentsOf: fileURL)
      return try decoder.decode([TranscriptHistoryEntry].self, from: data)
    } catch {
      try quarantineCorruptFile()
      throw VaniFailure.historyCorrupt
    }
  }

  public func append(_ entry: TranscriptHistoryEntry, limit: Int) throws {
    var entries = (try? load()) ?? []
    entries.insert(entry, at: 0)
    entries = Array(entries.prefix(min(max(limit, 10), 500)))
    try write(entries)
  }

  public func clear() throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    try fileManager.removeItem(at: fileURL)
  }

  private func write(_ entries: [TranscriptHistoryEntry]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let data = try encoder.encode(entries)
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func quarantineCorruptFile() throws {
    let stamp = Int(Date().timeIntervalSince1970)
    let quarantineURL =
      fileURL
      .deletingPathExtension()
      .appendingPathExtension("corrupt-\(stamp).json")
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.moveItem(at: fileURL, to: quarantineURL)
    }
  }
}

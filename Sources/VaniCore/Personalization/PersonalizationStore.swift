import Foundation

enum PersonalizationStoreError: Error, Equatable {
  case corrupt
  case fileTooLarge
  case unsafeDirectory
}

private struct StoredPersonalizationProfile: Codable, Sendable, Equatable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let corrections: [LearnedCorrection]

  init(corrections: [LearnedCorrection]) {
    schemaVersion = Self.currentSchemaVersion
    self.corrections = corrections
  }
}

public actor PersonalizationStore {
  private static let profileFileName = "personalization.json"
  private static let quarantinePrefix = "personalization.corrupt-"
  private static let quarantineSuffix = ".json"
  static let maximumProfileFileBytes = 1 * 1_024 * 1_024

  private let fileManager: FileManager
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let engine: PersonalizationEngine

  public init(
    directory: URL? = nil,
    fileManager: FileManager = .default,
    engine: PersonalizationEngine = PersonalizationEngine()
  ) {
    self.fileManager = fileManager
    let baseDirectory =
      directory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vani", isDirectory: true)
    fileURL = baseDirectory.appendingPathComponent(Self.profileFileName)
    self.engine = engine

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  public func load() throws -> [LearnedCorrection] {
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
        fileSize <= Self.maximumProfileFileBytes
      else {
        throw PersonalizationStoreError.corrupt
      }
      let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
      let profile = try decoder.decode(StoredPersonalizationProfile.self, from: data)
      guard profile.schemaVersion == StoredPersonalizationProfile.currentSchemaVersion else {
        throw PersonalizationStoreError.corrupt
      }
      return PersonalizationEngine.normalizedProfile(profile.corrections)
    } catch {
      try quarantineCorruptFile()
      throw PersonalizationStoreError.corrupt
    }
  }

  public func learn(
    original: String,
    corrected: String,
    applicationBundleIdentifier: String?,
    now: Date = Date()
  ) throws -> PersonalizationLearningResult {
    let existing = try loadRecoveringFromCorruption()
    let result = engine.learn(
      original: original,
      corrected: corrected,
      applicationBundleIdentifier: applicationBundleIdentifier,
      existing: existing,
      now: now
    )
    if !result.learned.isEmpty {
      try write(result.corrections)
    }
    return result
  }

  public func remove(ids: Set<UUID>) throws -> [LearnedCorrection] {
    var corrections = try loadRecoveringFromCorruption()
    corrections.removeAll { ids.contains($0.id) }
    try write(corrections)
    return corrections
  }

  public func clear() throws {
    for storedURL in try storedDataURLs() {
      try fileManager.removeItem(at: storedURL)
    }
  }

  public func hasStoredData() throws -> Bool {
    try !storedDataURLs().isEmpty
  }

  private func loadRecoveringFromCorruption() throws -> [LearnedCorrection] {
    do {
      return try load()
    } catch PersonalizationStoreError.corrupt {
      return []
    }
  }

  private func write(_ corrections: [LearnedCorrection]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try prepareSafeDirectory(directory)
    let profile = StoredPersonalizationProfile(
      corrections: PersonalizationEngine.normalizedProfile(corrections)
    )
    let data = try encoder.encode(profile)
    guard data.count <= Self.maximumProfileFileBytes else {
      throw PersonalizationStoreError.fileTooLarge
    }
    try data.write(to: fileURL, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func prepareSafeDirectory(_ directory: URL) throws {
    if fileManager.fileExists(atPath: directory.path) {
      let values = try directory.resourceValues(forKeys: [
        .isDirectoryKey,
        .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw PersonalizationStoreError.unsafeDirectory
      }
    } else {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func quarantineCorruptFile() throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    let stamp = Int(Date().timeIntervalSince1970)
    let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      "\(Self.quarantinePrefix)\(stamp)-\(UUID().uuidString)\(Self.quarantineSuffix)"
    )
    try fileManager.moveItem(at: fileURL, to: quarantineURL)
  }

  private func storedDataURLs() throws -> [URL] {
    let directory = fileURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let directoryValues = try directory.resourceValues(forKeys: [
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
      throw PersonalizationStoreError.unsafeDirectory
    }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ).filter { url in
      let name = url.lastPathComponent
      guard
        name == Self.profileFileName
          || (name.hasPrefix(Self.quarantinePrefix) && name.hasSuffix(Self.quarantineSuffix))
      else {
        return false
      }
      guard
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

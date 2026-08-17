import Foundation
import Testing

@testable import VaniCore

private func personalizationTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vani-personalization-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test
func personalizationStoreRoundTripsWithPrivatePermissions() async throws {
  let directory = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PersonalizationStore(directory: directory)

  let result = try await store.learn(
    original: "Vanny",
    corrected: "Vani",
    applicationBundleIdentifier: "test.app",
    now: Date(timeIntervalSince1970: 1_000)
  )
  #expect(result.learned.count == 1)

  let loaded = try await store.load()
  #expect(loaded == result.corrections)
  let fileURL = directory.appendingPathComponent("personalization.json")
  let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test
func personalizationStoreQuarantinesCorruptionBeforeStartingFresh() async throws {
  let directory = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let fileURL = directory.appendingPathComponent("personalization.json")
  try Data("not json".utf8).write(to: fileURL)
  let store = PersonalizationStore(directory: directory)

  await #expect(throws: PersonalizationStoreError.corrupt) {
    try await store.load()
  }
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(!names.contains("personalization.json"))
  #expect(names.contains(where: { $0.hasPrefix("personalization.corrupt-") }))

  _ = try await store.learn(
    original: "Vanny",
    corrected: "Vani",
    applicationBundleIdentifier: nil
  )
  #expect(try await store.load().count == 1)
}

@Test
func personalizationStoreNeverReadsASymlinkedProfile() async throws {
  let directory = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("unrelated.txt")
  try Data("private unrelated content".utf8).write(to: target)
  let profile = directory.appendingPathComponent("personalization.json")
  try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
  let store = PersonalizationStore(directory: directory)

  await #expect(throws: PersonalizationStoreError.corrupt) {
    try await store.load()
  }
  #expect(
    String(decoding: try Data(contentsOf: target), as: UTF8.self) == "private unrelated content")
}

@Test
func personalizationStoreRejectsASymlinkedRootDirectory() async throws {
  let root = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let realDirectory = root.appendingPathComponent("real", isDirectory: true)
  try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
  let link = root.appendingPathComponent("linked", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDirectory)
  let store = PersonalizationStore(directory: link)

  await #expect(throws: PersonalizationStoreError.unsafeDirectory) {
    _ = try await store.learn(
      original: "Vanny",
      corrected: "Vani",
      applicationBundleIdentifier: nil
    )
  }
}

@Test
func concurrentPersonalizationTransactionsDoNotLoseCorrections() async throws {
  let directory = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PersonalizationStore(directory: directory)

  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<30 {
      group.addTask {
        _ = try await store.learn(
          original: "heard-term-\(index)",
          corrected: "Canonical-Term-\(index)",
          applicationBundleIdentifier: nil,
          now: Date(timeIntervalSince1970: Double(index))
        )
      }
    }
    try await group.waitForAll()
  }

  #expect(try await store.load().count == 30)
}

@Test
func clearingPersonalizationRemovesActiveAndQuarantinedData() async throws {
  let directory = try personalizationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PersonalizationStore(directory: directory)
  _ = try await store.learn(
    original: "Vanny",
    corrected: "Vani",
    applicationBundleIdentifier: nil
  )
  let quarantine = directory.appendingPathComponent("personalization.corrupt-test.json")
  try Data("bad".utf8).write(to: quarantine)
  let unrelated = directory.appendingPathComponent("unrelated.txt")
  try Data("keep".utf8).write(to: unrelated)

  try await store.clear()

  #expect(!(try await store.hasStoredData()))
  #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

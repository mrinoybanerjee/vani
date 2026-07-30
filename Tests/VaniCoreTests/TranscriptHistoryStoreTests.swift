import Foundation
import Testing

@testable import VaniCore

@Test
func historyIsNewestFirstAndBounded() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = TranscriptHistoryStore(directory: directory)

  for index in 0..<12 {
    try await store.append(
      TranscriptHistoryEntry(text: "entry-\(index)"),
      limit: 10
    )
  }

  let entries = try await store.load()
  #expect(entries.count == 10)
  #expect(entries.first?.text == "entry-11")
  #expect(entries.last?.text == "entry-2")

  let directoryMode =
    try FileManager.default.attributesOfItem(atPath: directory.path)[
      .posixPermissions
    ] as? NSNumber
  let fileMode =
    try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("history.json").path
    )[.posixPermissions] as? NSNumber
  #expect(directoryMode?.intValue == 0o700)
  #expect(fileMode?.intValue == 0o600)
}

@Test
func corruptHistoryIsQuarantined() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("not-json".utf8).write(to: directory.appendingPathComponent("history.json"))
  let store = TranscriptHistoryStore(directory: directory)

  await #expect(throws: VaniFailure.historyCorrupt) {
    try await store.load()
  }

  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(files.contains(where: { $0.contains("corrupt-") }))
  #expect(!files.contains("history.json"))
  #expect(try await store.hasStoredData())
}

@Test
func symlinkedHistoryIsQuarantinedWithoutReadingOrDeletingItsTarget() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  let target = root.appendingPathComponent("private.json")
  try Data("private".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("history.json"),
    withDestinationURL: target
  )
  let store = TranscriptHistoryStore(directory: directory)

  await #expect(throws: VaniFailure.historyCorrupt) {
    try await store.load()
  }
  try await store.clear()

  #expect(try Data(contentsOf: target) == Data("private".utf8))
  #expect(try await !store.hasStoredData())
}

@Test
func clearRemovesCurrentAndQuarantinedHistoryButLeavesUnrelatedFiles() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  let historyURL = directory.appendingPathComponent("history.json")
  try Data("not-json".utf8).write(to: historyURL)
  let store = TranscriptHistoryStore(directory: directory)
  await #expect(throws: VaniFailure.historyCorrupt) {
    try await store.load()
  }

  try Data("valid".utf8).write(to: historyURL)
  let unrelatedURL = directory.appendingPathComponent("keep.txt")
  try Data("keep".utf8).write(to: unrelatedURL)
  let similarlyNamedDirectory = directory.appendingPathComponent(
    "history.corrupt-do-not-delete.json",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: similarlyNamedDirectory,
    withIntermediateDirectories: false
  )

  #expect(try await store.hasStoredData())
  try await store.clear()

  #expect(try await !store.hasStoredData())
  #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(Set(files) == ["history.corrupt-do-not-delete.json", "keep.txt"])
}

@Test
func appendAfterCorruptionStartsFreshHistoryAndPreservesQuarantine() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("not-json".utf8).write(to: directory.appendingPathComponent("history.json"))
  let store = TranscriptHistoryStore(directory: directory)
  let entry = TranscriptHistoryEntry(text: "fresh")

  try await store.append(entry, limit: 100)

  let loaded = try await store.load()
  #expect(loaded.count == 1)
  #expect(loaded.first?.id == entry.id)
  #expect(loaded.first?.text == entry.text)
  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(files.filter { $0.hasPrefix("history.corrupt-") }.count == 1)
}

@Test
func oversizedHistoryIsQuarantinedBeforeItIsRead() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let historyURL = directory.appendingPathComponent("history.json")
  #expect(FileManager.default.createFile(atPath: historyURL.path, contents: nil))
  let handle = try FileHandle(forWritingTo: historyURL)
  try handle.truncate(
    atOffset: UInt64(TranscriptHistoryStore.maximumHistoryFileBytes + 1)
  )
  try handle.close()
  let store = TranscriptHistoryStore(directory: directory)

  await #expect(throws: VaniFailure.historyCorrupt) {
    try await store.load()
  }

  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(!files.contains("history.json"))
  #expect(files.filter { $0.hasPrefix("history.corrupt-") }.count == 1)
}

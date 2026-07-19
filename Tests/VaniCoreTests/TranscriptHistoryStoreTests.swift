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
}

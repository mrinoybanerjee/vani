import Foundation
import Testing

@testable import VaniCore

private let testRevision = String(repeating: "a", count: 40)

@Test
func pinnedModelDownloaderInstallsOnlyVerifiedFiles() async throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appendingPathComponent("model", isDirectory: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  try Data("old".utf8).write(to: target.appendingPathComponent("old.bin"))

  let artifacts = [
    ModelArtifact(
      path: "Encoder.mlmodelc/metadata.json",
      byteCount: 5,
      sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    ),
    ModelArtifact(
      path: "vocab.json",
      byteCount: 5,
      sha256: "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
    ),
  ]
  let payloads = ["metadata.json": Data("hello".utf8), "vocab.json": Data("world".utf8)]
  let downloader = PinnedModelDownloader(
    repository: "owner/model",
    revision: testRevision,
    verifier: ModelIntegrityVerifier(artifacts: artifacts),
    retryLimit: 1,
    fetch: { url in
      guard url.path.contains("/owner/model/resolve/\(testRevision)/") else {
        throw PinnedModelDownloadError.invalidSource
      }
      let data = try #require(payloads[url.lastPathComponent])
      let temporaryURL = temporaryFileURL()
      try data.write(to: temporaryURL)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      return (temporaryURL, response)
    }
  )

  try await downloader.install(at: target) { _ in }

  #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old.bin").path))
  #expect(
    try Data(contentsOf: target.appendingPathComponent("Encoder.mlmodelc/metadata.json"))
      == Data("hello".utf8)
  )
  #expect(try Data(contentsOf: target.appendingPathComponent("vocab.json")) == Data("world".utf8))
}

@Test
func pinnedModelDownloaderRejectsUnsafePathsBeforeFetching() async {
  let downloader = PinnedModelDownloader(
    repository: "owner/model",
    revision: testRevision,
    verifier: ModelIntegrityVerifier(
      artifacts: [ModelArtifact(path: "../escape", byteCount: 1, sha256: "00")]
    ),
    retryLimit: 1,
    fetch: { _ in throw PinnedModelDownloadError.invalidResponse }
  )

  await #expect(throws: PinnedModelDownloadError.invalidSource) {
    try await downloader.install(at: temporaryDirectory()) { _ in }
  }
}

@Test
func failedPinnedModelDownloadLeavesExistingDirectoryUntouched() async throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appendingPathComponent("model", isDirectory: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  let marker = target.appendingPathComponent("existing.txt")
  try Data("keep".utf8).write(to: marker)

  let downloader = PinnedModelDownloader(
    repository: "owner/model",
    revision: testRevision,
    verifier: ModelIntegrityVerifier(
      artifacts: [
        ModelArtifact(
          path: "model.bin",
          byteCount: 5,
          sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
      ]
    ),
    retryLimit: 1,
    fetch: { url in
      let temporaryURL = temporaryFileURL()
      try Data("bad".utf8).write(to: temporaryURL)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      return (temporaryURL, response)
    }
  )

  await #expect(throws: PinnedModelDownloadError.invalidArtifact) {
    try await downloader.install(at: target) { _ in }
  }
  #expect(try Data(contentsOf: marker) == Data("keep".utf8))
}

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "VaniPinnedModelTests-\(UUID().uuidString)",
    isDirectory: true
  )
}

private func temporaryFileURL() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "VaniPinnedModelFile-\(UUID().uuidString)"
  )
}

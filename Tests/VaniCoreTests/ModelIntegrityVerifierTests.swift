import CryptoKit
import Foundation
import Testing

@testable import VaniCore

@Test
func modelIntegrityAcceptsExactManifest() throws {
  let fixture = try ModelIntegrityFixture()
  defer { fixture.remove() }

  try fixture.verifier.verify(directory: fixture.directory)
}

@Test
func modelIntegrityRejectsTamperedArtifact() throws {
  let fixture = try ModelIntegrityFixture()
  defer { fixture.remove() }
  try Data("tampered".utf8).write(to: fixture.artifactURL)

  #expect(throws: VaniFailure.modelIntegrityFailed) {
    try fixture.verifier.verify(directory: fixture.directory)
  }
}

@Test
func modelIntegrityRejectsUnexpectedModelFile() throws {
  let fixture = try ModelIntegrityFixture()
  defer { fixture.remove() }
  try Data().write(
    to: fixture.directory.appendingPathComponent("Decoder.mlmodelc/unexpected.bin")
  )

  #expect(throws: VaniFailure.modelIntegrityFailed) {
    try fixture.verifier.verify(directory: fixture.directory)
  }
}

@Test
func modelIntegrityRejectsSymlinkedArtifact() throws {
  let fixture = try ModelIntegrityFixture()
  defer { fixture.remove() }
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: source) }
  try Data("verified".utf8).write(to: source)
  try FileManager.default.removeItem(at: fixture.artifactURL)
  try FileManager.default.createSymbolicLink(at: fixture.artifactURL, withDestinationURL: source)

  #expect(throws: VaniFailure.modelIntegrityFailed) {
    try fixture.verifier.verify(directory: fixture.directory)
  }
}

private struct ModelIntegrityFixture {
  let directory: URL
  let artifactURL: URL
  let verifier: ModelIntegrityVerifier

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    artifactURL = directory.appendingPathComponent("Decoder.mlmodelc/model.mil")
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = Data("verified".utf8)
    try data.write(to: artifactURL)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    verifier = ModelIntegrityVerifier(
      artifacts: [
        ModelArtifact(path: "Decoder.mlmodelc/model.mil", byteCount: data.count, sha256: digest)
      ]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

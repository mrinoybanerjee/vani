import CryptoKit
import Foundation

struct ModelArtifact: Sendable, Equatable {
  let path: String
  let byteCount: Int
  let sha256: String
}

struct ModelIntegrityVerifier: Sendable {
  static let parakeetV2Revision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
  static let parakeetCtc110MRevision = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"

  static let parakeetV2 = ModelIntegrityVerifier(artifacts: [
    ModelArtifact(
      path: "Decoder.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
    ModelArtifact(
      path: "Decoder.mlmodelc/coremldata.bin", byteCount: 554,
      sha256: "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
    ModelArtifact(
      path: "Decoder.mlmodelc/metadata.json", byteCount: 3_427,
      sha256: "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
    ModelArtifact(
      path: "Decoder.mlmodelc/model.mil", byteCount: 13_106,
      sha256: "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
    ModelArtifact(
      path: "Decoder.mlmodelc/weights/weight.bin", byteCount: 14_429_952,
      sha256: "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
    ModelArtifact(
      path: "Encoder.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
    ModelArtifact(
      path: "Encoder.mlmodelc/coremldata.bin", byteCount: 485,
      sha256: "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
    ModelArtifact(
      path: "Encoder.mlmodelc/metadata.json", byteCount: 2_926,
      sha256: "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
    ModelArtifact(
      path: "Encoder.mlmodelc/model.mil", byteCount: 959_769,
      sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
    ModelArtifact(
      path: "Encoder.mlmodelc/weights/weight.bin", byteCount: 445_187_200,
      sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
    ModelArtifact(
      path: "JointDecision.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
    ModelArtifact(
      path: "JointDecision.mlmodelc/coremldata.bin", byteCount: 534,
      sha256: "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
    ModelArtifact(
      path: "JointDecision.mlmodelc/metadata.json", byteCount: 2_936,
      sha256: "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
    ModelArtifact(
      path: "JointDecision.mlmodelc/model.mil", byteCount: 9_722,
      sha256: "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
    ModelArtifact(
      path: "JointDecision.mlmodelc/weights/weight.bin", byteCount: 3_453_388,
      sha256: "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/coremldata.bin", byteCount: 494,
      sha256: "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/metadata.json", byteCount: 2_974,
      sha256: "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/model.mil", byteCount: 27_166,
      sha256: "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/weights/weight.bin", byteCount: 298_880,
      sha256: "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
    ModelArtifact(
      path: "config.json", byteCount: 3,
      sha256: "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356"),
    ModelArtifact(
      path: "parakeet_vocab.json", byteCount: 18_762,
      sha256: "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
  ])

  static let parakeetCtc110M = ModelIntegrityVerifier(artifacts: [
    ModelArtifact(
      path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"),
    ModelArtifact(
      path: "AudioEncoder.mlmodelc/coremldata.bin", byteCount: 505,
      sha256: "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"),
    ModelArtifact(
      path: "AudioEncoder.mlmodelc/metadata.json", byteCount: 3_456,
      sha256: "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2"),
    ModelArtifact(
      path: "AudioEncoder.mlmodelc/model.mil", byteCount: 1_060_924,
      sha256: "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e"),
    ModelArtifact(
      path: "AudioEncoder.mlmodelc/weights/weight.bin", byteCount: 100_778_304,
      sha256: "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"),
    ModelArtifact(
      path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", byteCount: 243,
      sha256: "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"),
    ModelArtifact(
      path: "MelSpectrogram.mlmodelc/coremldata.bin", byteCount: 330,
      sha256: "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"),
    ModelArtifact(
      path: "MelSpectrogram.mlmodelc/metadata.json", byteCount: 1_962,
      sha256: "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3"),
    ModelArtifact(
      path: "MelSpectrogram.mlmodelc/model.mil", byteCount: 12_584,
      sha256: "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79"),
    ModelArtifact(
      path: "MelSpectrogram.mlmodelc/weights/weight.bin", byteCount: 567_712,
      sha256: "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"),
    ModelArtifact(
      path: "tokenizer.json", byteCount: 360_106,
      sha256: "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db"),
    ModelArtifact(
      path: "vocab.json", byteCount: 16_086,
      sha256: "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f"),
  ])

  let artifacts: [ModelArtifact]

  func verify(directory: URL, fileManager: FileManager = .default) throws {
    let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    let expectedPaths = Set(artifacts.map(\.path))
    guard try relevantFilePaths(in: directory, fileManager: fileManager) == expectedPaths else {
      throw VaniFailure.modelIntegrityFailed
    }

    for artifact in artifacts {
      guard isSafeRelativePath(artifact.path) else {
        throw VaniFailure.modelIntegrityFailed
      }
      let url = directory.appendingPathComponent(artifact.path)
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.fileSize == artifact.byteCount,
        try sha256(of: url) == artifact.sha256
      else {
        throw VaniFailure.modelIntegrityFailed
      }
    }
  }

  private func relevantFilePaths(
    in directory: URL,
    fileManager: FileManager
  ) throws -> Set<String> {
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
      )
    else {
      throw VaniFailure.modelIntegrityFailed
    }

    var paths: Set<String> = []
    for case let url as URL in enumerator {
      let rootComponents = directory.pathComponents
      let fileComponents = url.standardizedFileURL.pathComponents
      guard fileComponents.starts(with: rootComponents) else {
        throw VaniFailure.modelIntegrityFailed
      }
      let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")

      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw VaniFailure.modelIntegrityFailed
      }
      if values.isRegularFile == true {
        paths.insert(relative)
      }
    }
    return paths
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

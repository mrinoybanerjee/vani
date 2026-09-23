// swift-tools-version: 6.0
import Foundation
import PackageDescription

let version = ProcessInfo.processInfo.environment["FLUIDAUDIO_VERSION"] ?? "0.15.8"
let package = Package(
  name: "AsrBench",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: Version(stringLiteral: version))
  ],
  targets: [
    .executableTarget(
      name: "AsrBench",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
    )
  ]
)

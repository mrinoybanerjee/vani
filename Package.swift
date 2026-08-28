// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Vani",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "VaniCore", targets: ["VaniCore"]),
    .executable(name: "Vani", targets: ["Vani"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.15.6"
    )
  ],
  targets: [
    .target(
      name: "VaniCore",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio")
      ]
    ),
    .executableTarget(
      name: "Vani",
      dependencies: ["VaniCore"]
    ),
    .testTarget(
      name: "VaniCoreTests",
      dependencies: ["VaniCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "VaniAppTests",
      dependencies: ["Vani"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

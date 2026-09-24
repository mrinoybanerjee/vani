// Renders Resources/AppIcon.png and Resources/AppIcon.icns from code.
// Usage, from the repository root: swift scripts/make-app-icon.swift   (then commit both files)
// The mark geometry matches VaniMark in Sources/Vani/VaniTheme.swift.
import AppKit
import SwiftUI

let forest = Color(red: 0x31 / 255, green: 0x5E / 255, blue: 0x48 / 255)
let forestDeep = Color(red: 0x27 / 255, green: 0x4C / 255, blue: 0x3A / 255)
let paper = Color(red: 0xFA / 255, green: 0xF9 / 255, blue: 0xF6 / 255)

/// Five bars sharing a top line; their falling lengths form a V.
struct Mark: View {
  var body: some View {
    HStack(alignment: .top, spacing: 36) {
      ForEach(Array([150.0, 270.0, 400.0, 270.0, 150.0].enumerated()), id: \.offset) { _, length in
        Capsule().fill(paper).frame(width: 56, height: length)
      }
    }
    .frame(height: 400, alignment: .top)
    .offset(y: 20)
  }
}

/// macOS icon grid: an 824-point continuous rounded square centred in 1024, with shadow.
struct Icon: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(LinearGradient(colors: [forest, forestDeep], startPoint: .top, endPoint: .bottom))
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
      Mark()
    }
    .frame(width: 1024, height: 1024)
  }
}

@MainActor func png(pixels: Int) -> Data {
  let renderer = ImageRenderer(content: Icon())
  renderer.scale = CGFloat(pixels) / 1024
  let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
  return rep.representation(using: .png, properties: [:])!
}

@MainActor func run() throws {
  let resources = URL(fileURLWithPath: "Resources", isDirectory: true)
  guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Info.plist").path)
  else {
    print("Run from the repository root.")
    exit(1)
  }
  try png(pixels: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
  let iconset = FileManager.default.temporaryDirectory.appendingPathComponent(
    "Vani-\(UUID().uuidString).iconset")
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: iconset) }
  for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(
      to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
  }
  let iconutil = Process()
  iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  iconutil.arguments = [
    "-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path,
  ]
  try iconutil.run()
  iconutil.waitUntilExit()
  guard iconutil.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
  print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")
}

try MainActor.assumeIsolated { try run() }

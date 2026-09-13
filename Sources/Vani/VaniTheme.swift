import AppKit
import SwiftUI

/// Presentation-only tokens. System labels and controls retain macOS contrast and focus behavior.
enum VaniTheme {
  static let paper = adaptive(light: 0xFAF9F6, dark: 0x202321)
  static let sidebar = adaptive(light: 0xF0F0EA, dark: 0x191C1A)
  static let accent = adaptive(light: 0x315E48, dark: 0xA4C9AD)
  static let line = Color.primary.opacity(0.10)

  private static func adaptive(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          red: CGFloat((value >> 16) & 255) / 255,
          green: CGFloat((value >> 8) & 255) / 255,
          blue: CGFloat(value & 255) / 255, alpha: 1)
      })
  }
}

struct VaniWordmark: View {
  var size: CGFloat = 22

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "waveform")
        .font(.system(size: size - 2, weight: .medium))
        .foregroundStyle(VaniTheme.accent)
        .accessibilityHidden(true)
      Text("vani").font(.system(size: size, weight: .semibold, design: .rounded))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Vani")
  }
}

struct ShortcutKey: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 6))
      .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(VaniTheme.line) }
  }
}

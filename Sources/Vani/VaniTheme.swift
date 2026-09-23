import AppKit
import SwiftUI
import VaniCore

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
    HStack(spacing: 8) {
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

/// View-layer names for the hold shortcut. The core enum keeps its persisted identity.
extension HoldShortcut {
  var displayName: String {
    switch self {
    case .leftControl: "Left Control"
    case .rightOption: "Right Option"
    case .rightCommand: "Right Command"
    case .function: "Fn / Globe"
    }
  }

  /// Text printed on the physical key.
  var keycapLabel: String {
    switch self {
    case .leftControl: "⌃ control"
    case .rightOption: "⌥ option"
    case .rightCommand: "⌘ command"
    case .function: "fn"
    }
  }

  var keycapSymbol: String? { self == .function ? "globe" : nil }
}

struct ShortcutKey: View {
  let label: String
  var systemImage: String?
  var accessibilityName: String?

  init(label: String, systemImage: String? = nil, accessibilityName: String? = nil) {
    self.label = label
    self.systemImage = systemImage
    self.accessibilityName = accessibilityName
  }

  init(shortcut: HoldShortcut) {
    self.init(
      label: shortcut.keycapLabel, systemImage: shortcut.keycapSymbol,
      accessibilityName: shortcut.displayName)
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage).imageScale(.small)
      }
      Text(label)
    }
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 8).padding(.vertical, 4)
    .frame(minHeight: 24)
    .background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 6))
    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.22)) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(accessibilityName ?? label) key")
  }
}

/// The macOS Keyboard setting "Press 🌐 key to". Vani only reads it.
enum GlobeKeyAction: Equatable {
  case doNothing
  case changeInputSource
  case showEmojiAndSymbols
  case startDictation
  case unknown

  init(preferenceValue: Int?) {
    switch preferenceValue {
    case 0: self = .doNothing
    case 1: self = .changeInputSource
    case 2: self = .showEmojiAndSymbols
    case 3: self = .startDictation
    default: self = .unknown
    }
  }

  static func current() -> GlobeKeyAction {
    let domain = "com.apple.HIToolbox" as CFString
    CFPreferencesAppSynchronize(domain)
    let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? NSNumber
    return GlobeKeyAction(preferenceValue: value?.intValue)
  }

  static let keyboardSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

  static func openKeyboardSettings() {
    NSWorkspace.shared.open(keyboardSettingsURL)
  }
}

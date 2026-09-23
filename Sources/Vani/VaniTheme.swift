import AppKit
import SwiftUI
import VaniCore

/// Presentation-only tokens. System labels and controls retain macOS contrast and focus behavior.
/// With Increase Contrast, the accent deepens and hairlines become clearly visible.
enum VaniTheme {
  static let paper = adaptive(light: 0xFAF9F6, dark: 0x202321)
  static let sidebar = adaptive(light: 0xF0F0EA, dark: 0x191C1A)
  static let accent = adaptive(
    light: 0x315E48, dark: 0xA4C9AD, highContrastLight: 0x1B3A2B, highContrastDark: 0xC8E6CF)
  static let line = Color(
    nsColor: NSColor(name: nil) { appearance in
      let alpha: CGFloat = isHighContrast(appearance) ? 0.45 : 0.10
      return (isDark(appearance) ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
    })

  private static let appearances: [NSAppearance.Name] = [
    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
  ]

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    let match = appearance.bestMatch(from: appearances)
    return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
  }

  private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
    let match = appearance.bestMatch(from: appearances)
    return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
  }

  private static func adaptive(
    light: Int, dark: Int, highContrastLight: Int? = nil, highContrastDark: Int? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let highContrast = isHighContrast(appearance)
        let value =
          isDark(appearance)
          ? (highContrast ? highContrastDark ?? dark : dark)
          : (highContrast ? highContrastLight ?? light : light)
        return NSColor(
          red: CGFloat((value >> 16) & 255) / 255,
          green: CGFloat((value >> 8) & 255) / 255,
          blue: CGFloat(value & 255) / 255, alpha: 1)
      })
  }
}

/// The selected-row treatment shared by navigation, filters and library rows. The fill is
/// paired with a weight change or accent bar in each row; with Increase Contrast or Differentiate
/// Without Color, a visible outline is added so selection never depends on a subtle fill.
struct SelectionHighlight: ViewModifier {
  let selected: Bool
  let cornerRadius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  func body(content: Content) -> some View {
    content
      .background(
        selected ? VaniTheme.paper : .clear, in: RoundedRectangle(cornerRadius: cornerRadius)
      )
      .overlay {
        if selected, contrast == .increased || differentiateWithoutColor {
          RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(VaniTheme.accent, lineWidth: 1.5)
        }
      }
  }
}

extension View {
  func selectionHighlight(_ selected: Bool, cornerRadius: CGFloat) -> some View {
    modifier(SelectionHighlight(selected: selected, cornerRadius: cornerRadius))
  }
}

/// Speaks brief state changes that VoiceOver users would otherwise miss. Messages name the state
/// only; they never include transcript, note or meeting content.
@MainActor
enum VoiceOverAnnouncer {
  /// Replaced in tests to observe announcements.
  static var post: @MainActor (String) -> Void = { message in
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  static func announce(_ message: String) { post(message) }
}

/// Download progress is announced at quarter milestones, not on every update.
enum ProgressMilestone {
  static func crossed(from old: Double?, to new: Double?) -> Int? {
    guard let new else { return nil }
    let previous = Int((old ?? 0) * 4)
    let current = Int(min(max(new, 0), 1) * 4)
    guard current > previous, current > 0 else { return nil }
    return current * 25
  }
}

extension View {
  /// Announces "<subject> 25 percent" and so on as a download progresses.
  func announcesProgressMilestones(_ progress: Double?, subject: String) -> some View {
    onChange(of: progress) { old, new in
      guard let percent = ProgressMilestone.crossed(from: old, to: new) else { return }
      VoiceOverAnnouncer.announce("\(subject) \(percent) percent")
    }
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

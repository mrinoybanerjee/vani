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

/// The Vani mark: five bars whose shared top line and falling lengths form a V, a waveform
/// that reads as the letter. Geometry matches `scripts/make-app-icon.swift`.
struct VaniMark: Shape {
  static let barLengths: [CGFloat] = [150, 270, 400, 270, 150]
  static let barWidth: CGFloat = 56
  static let barSpacing: CGFloat = 36
  static let designSize = CGSize(width: 5 * 56 + 4 * 36, height: 400)
  static var aspectRatio: CGFloat { designSize.width / designSize.height }

  /// Extra length per bar, in design units, drawn below the rest mark. The live mark uses it to
  /// follow the voice; the shared top line never moves. Empty draws the mark itself.
  var growth: [CGFloat] = []

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width / Self.designSize.width, rect.height / Self.designSize.height)
    let origin = CGPoint(
      x: rect.midX - Self.designSize.width * scale / 2,
      y: rect.midY - Self.designSize.height * scale / 2)
    var path = Path()
    for (index, length) in Self.barLengths.enumerated() {
      let extra = index < growth.count ? max(0, growth[index]) : 0
      let bar = CGRect(
        x: origin.x + CGFloat(index) * (Self.barWidth + Self.barSpacing) * scale,
        y: origin.y, width: Self.barWidth * scale, height: (length + extra) * scale)
      path.addRoundedRect(
        in: bar, cornerSize: CGSize(width: bar.width / 2, height: bar.width / 2))
    }
    return path
  }

  /// How the menu bar draws the mark.
  enum MenuBarStyle: Equatable {
    /// The mark alone: ready, or dimmed while not ready.
    case mark
    /// The mark cut out of a rounded tile, echoing the app icon: recording or transcribing.
    /// Its bars can grow inside the tile.
    case tile
    /// The mark with a dot: something needs attention.
    case badged
  }

  /// A monochrome template for the menu bar, tinted by macOS for light and dark menus.
  @MainActor static func menuBarImage(
    style: MenuBarStyle = .mark, opacity: CGFloat = 1, growth: [CGFloat] = []
  ) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: true) { bounds in
      NSColor.black.withAlphaComponent(opacity).setFill()
      switch style {
      case .mark, .badged:
        let markHeight: CGFloat = 13
        let rect = CGRect(
          x: (bounds.width - markHeight * aspectRatio) / 2, y: (bounds.height - markHeight) / 2,
          width: markHeight * aspectRatio, height: markHeight)
        let mark = NSBezierPath(cgPath: VaniMark().path(in: rect).cgPath)
        guard style == .badged else {
          mark.fill()
          return true
        }
        // Clear a ring around the dot so it reads apart from the bars.
        let dot = CGRect(x: bounds.maxX - 6, y: bounds.maxY - 6, width: 6, height: 6)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: bounds)
        clip.appendOval(in: dot.insetBy(dx: -1.5, dy: -1.5))
        clip.windingRule = .evenOdd
        clip.addClip()
        mark.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSBezierPath(ovalIn: dot).fill()
      case .tile:
        let tileRect = bounds.insetBy(dx: 0.5, dy: 1)
        let markHeight: CGFloat = 9
        // The mark sits high in the tile, leaving room for its bars to grow with the voice.
        let rect = CGRect(
          x: (bounds.width - markHeight * aspectRatio) / 2, y: 4,
          width: markHeight * aspectRatio, height: markHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tileRect, xRadius: 4.5, yRadius: 4.5).addClip()
        let tile = NSBezierPath(rect: tileRect)
        tile.append(NSBezierPath(cgPath: VaniMark(growth: growth).path(in: rect).cgPath))
        tile.windingRule = .evenOdd
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Vani"
    return image
  }
}

/// Frame-by-frame motion for the live mark, shared by the recording pill and the menu bar.
/// Listening: the mark stays dimmed until the microphone delivers its first audio, then its bars
/// lengthen with the voice, the centre leading, and rest as the exact mark in silence.
/// Transcribing: a slow ripple crosses the bars. Smoothing is time-based, so any frame rate
/// produces the same motion; tests drive it with a fake clock.
final class VaniMarkMotion {
  enum Activity: Equatable {
    case listening
    case transcribing
  }

  struct Frame: Equatable {
    var growth: [CGFloat]
    var opacity: Double
  }

  /// Growth at full voice, in mark design units; the centre bar is 400 long.
  static let maximumGrowth: CGFloat = 150
  /// Opacity while the microphone is starting.
  static let wakingOpacity = 0.5
  static let barWeights: [Double] = [0.7, 0.9, 1.0, 0.9, 0.7]
  static let rippleRange: ClosedRange<Double> = 0.05...0.4
  static let ripplePeriod: TimeInterval = 1.2

  private var growth: [Double] = Array(repeating: 0, count: 5)
  private var loudness: Double = 0
  private var opacity = wakingOpacity
  private var heardAudio = false
  private var lastTime: TimeInterval?

  func advance(activity: Activity, level rms: Float, time: TimeInterval) -> Frame {
    let elapsed = min(max(time - (lastTime ?? time - 1.0 / 60), 0), 0.25)
    lastTime = time
    func approach(_ value: inout Double, _ target: Double, timeConstant: Double) {
      value += (target - value) * (1 - exp(-elapsed / timeConstant))
    }

    if activity == .transcribing || rms > 0 { heardAudio = true }
    approach(&opacity, heardAudio ? 1 : Self.wakingOpacity, timeConstant: 0.06)

    let targets: [Double]
    switch activity {
    case .listening:
      let target = LevelMeter.normalized(rms)
      // Fast attack, slow release: syllables register at once and decay gently.
      approach(&loudness, target, timeConstant: target > loudness ? 0.03 : 0.16)
      targets = Self.barWeights.enumerated().map { index, weight in
        let bar = Double(index)
        let variation = 0.8 + 0.2 * sin(time * (5.5 + bar * 1.6) + bar * 1.3)
        return loudness * weight * variation
      }
    case .transcribing:
      loudness = 0
      let phase = time * 2 * .pi / Self.ripplePeriod
      let low = Self.rippleRange.lowerBound
      let span = Self.rippleRange.upperBound - low
      targets = (0..<5).map { index in
        low + span * (0.5 + 0.5 * sin(phase - Double(index) * 0.9))
      }
    }
    for index in growth.indices {
      approach(&growth[index], targets[index], timeConstant: 0.05)
    }
    return Frame(
      growth: growth.map { CGFloat($0) * Self.maximumGrowth }, opacity: min(1, opacity))
  }
}

/// The mark as the live indicator in the recording pill. Reduce Motion shows the still mark.
struct LiveVaniMark: View {
  let activity: VaniMarkMotion.Activity
  /// Microphone loudness (RMS) while listening.
  var level: @Sendable () -> Float = { 0 }
  var height: CGFloat = 18
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = VaniMarkMotion()

  var body: some View {
    if reduceMotion {
      mark(VaniMark())
    } else {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
        let frame = motion.advance(
          activity: activity, level: activity == .listening ? level() : 0,
          time: context.date.timeIntervalSinceReferenceDate)
        mark(VaniMark(growth: frame.growth)).opacity(frame.opacity)
      }
    }
  }

  /// Growth draws below the frame, so the rest mark stays centred beside the label.
  private func mark(_ shape: VaniMark) -> some View {
    shape.fill(VaniTheme.accent)
      .frame(width: height * VaniMark.aspectRatio, height: height)
  }
}

struct VaniWordmark: View {
  var size: CGFloat = 22

  var body: some View {
    HStack(spacing: 8) {
      VaniMark()
        .fill(VaniTheme.accent)
        .frame(width: (size - 4) * VaniMark.aspectRatio, height: size - 4)
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

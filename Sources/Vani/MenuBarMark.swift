import AppKit
import VaniCore

/// The menu bar icon. It is always the Vani mark: dimmed until dictation is ready, and badged
/// when something needs attention. While recording or transcribing it becomes the mark cut out
/// of a tile, echoing the app icon, so the state reads without motion; its bars follow the voice
/// and ripple while transcribing. Frames are published only when the drawing changes.
@MainActor
final class MenuBarMark: ObservableObject {
  enum Mode: Equatable {
    case ready
    case unavailable
    case listening
    case transcribing
    case attention

    init(phase: SessionPhase) {
      switch phase {
      case .ready: self = .ready
      case .setup, .preparing, .disabled: self = .unavailable
      case .listening: self = .listening
      case .transcribing, .inserting: self = .transcribing
      case .recoverableError: self = .attention
      }
    }

    var accessibilityLabel: String {
      switch self {
      case .ready: "Vani"
      case .unavailable: "Vani, not ready"
      case .listening: "Vani, listening"
      case .transcribing: "Vani, transcribing"
      case .attention: "Vani, needs attention"
      }
    }
  }

  static let framesPerSecond: Double = 15

  @Published private(set) var image: NSImage
  private(set) var mode: Mode = .unavailable
  /// Supplies the live microphone level while listening.
  var level: @Sendable () -> Float = { 0 }
  private var motion = VaniMarkMotion()
  private var timer: Timer?
  private var lastFrame: VaniMarkMotion.Frame?
  private let reduceMotion: () -> Bool

  init(
    reduceMotion: @escaping () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    self.reduceMotion = reduceMotion
    image = Self.stillImage(for: .unavailable)
  }

  var accessibilityLabel: String { mode.accessibilityLabel }
  var isAnimating: Bool { timer != nil }
  var style: VaniMark.MenuBarStyle { Self.style(for: mode) }

  func setMode(_ newMode: Mode) {
    guard newMode != mode else { return }
    let wasAnimating = mode == .listening || mode == .transcribing
    mode = newMode
    let animates = (newMode == .listening || newMode == .transcribing) && !reduceMotion()
    guard animates else {
      stopTimer()
      image = Self.stillImage(for: newMode)
      return
    }
    // Listening into transcribing keeps its motion, so the ripple grows out of the voice.
    if !wasAnimating || newMode == .listening {
      motion = VaniMarkMotion()
      lastFrame = nil
    }
    advance()
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
    // Common modes keep the icon moving while the menu is open.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Draws the next frame. Called by the timer; exposed for tests.
  func advance(at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
    let activity: VaniMarkMotion.Activity
    switch mode {
    case .listening: activity = .listening
    case .transcribing: activity = .transcribing
    case .ready, .unavailable, .attention: return
    }
    let frame = Self.quantized(
      motion.advance(
        activity: activity, level: activity == .listening ? level() : 0, time: time))
    guard frame != lastFrame else { return }
    lastFrame = frame
    image = VaniMark.menuBarImage(style: .tile, opacity: frame.opacity, growth: frame.growth)
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
    lastFrame = nil
  }

  /// Rounds a frame to what the 18 pt icon can show, so near-identical frames are not redrawn.
  static func quantized(_ frame: VaniMarkMotion.Frame) -> VaniMarkMotion.Frame {
    // The tile's mark is 9 pt tall, so eight design units draw as 0.18 pt: about a third of a
    // pixel on a Retina display.
    VaniMarkMotion.Frame(
      growth: frame.growth.map { ($0 / 8).rounded() * 8 },
      opacity: (frame.opacity * 20).rounded() / 20)
  }

  static func style(for mode: Mode) -> VaniMark.MenuBarStyle {
    switch mode {
    case .ready, .unavailable: .mark
    case .listening, .transcribing: .tile
    case .attention: .badged
    }
  }

  static func stillImage(for mode: Mode) -> NSImage {
    VaniMark.menuBarImage(style: style(for: mode), opacity: mode == .unavailable ? 0.45 : 1)
  }
}

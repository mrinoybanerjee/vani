import AppKit
import SwiftUI
import VaniCore

@MainActor
final class OverlayController {
  static let minimumWidth: CGFloat = 200
  static let maximumWidth: CGFloat = 340

  private(set) var state: OverlayState = .hidden
  /// Supplies the live microphone level while recording.
  var level: @Sendable () -> Float = { 0 }
  private var listeningStartedAt = Date()
  private let hosting: NSHostingController<OverlayView>
  private let panel: NSPanel
  private let announce: @MainActor (String) -> Void
  private var hideTask: Task<Void, Never>?
  /// Set while the pill answers a key press whose recording has not started yet.
  private var pendingStart: UInt64?
  /// A state shown for a press but not yet announced to VoiceOver.
  private var unannouncedState: OverlayState?
  private var startGeneration: UInt64 = 0
  private var visibilityGeneration: UInt64 = 0

  init(announce: @escaping @MainActor (String) -> Void = OverlayController.postAnnouncement) {
    self.announce = announce
    hosting = NSHostingController(
      rootView: OverlayView(state: .hidden, listeningStartedAt: Date()))
    hosting.sizingOptions = []
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 52),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.contentView = hosting.view
  }

  /// The overlay's hosting view, exposed for native snapshot tests.
  var contentView: NSView { hosting.view }
  var isVisible: Bool { panel.isVisible }
  var panelSize: NSSize { panel.frame.size }

  /// Set while a double-tap has locked recording on.
  var handsFree = false {
    didSet {
      guard handsFree != oldValue, state.isRecording, state != .recordingLimitWarning else {
        return
      }
      // During a pending start the session has not confirmed the recording yet.
      show(handsFree ? .handsFree : .listening, announces: unannouncedState == nil)
    }
  }

  /// Shows Listening the moment the shortcut is pressed, before the microphone has started;
  /// the mark stays dimmed until audio arrives. VoiceOver hears it only once the session
  /// confirms the recording. Returns a token for `abandonStart`.
  func showStarting() -> UInt64 {
    hideTask?.cancel()
    startGeneration &+= 1
    pendingStart = startGeneration
    show(handsFree ? .handsFree : .listening, announces: false)
    return startGeneration
  }

  /// The press never became a recording, and the session published nothing (it was cancelled
  /// or refused), so hide the pill it showed. With a token, only while that press still owns
  /// the pill; without one, whichever start is pending.
  func abandonStart(_ token: UInt64? = nil) {
    guard let pendingStart, token == nil || token == pendingStart else { return }
    self.pendingStart = nil
    unannouncedState = nil
    hide()
  }

  func update(snapshot: SessionSnapshot, previousPhase: SessionPhase) {
    // A ready snapshot published while a press is starting (a history update, say) is not
    // the outcome of that press and must not hide it.
    if pendingStart != nil, snapshot.phase == .ready { return }
    hideTask?.cancel()
    pendingStart = nil
    switch snapshot.phase {
    case .listening:
      show(
        snapshot.isRecordingLimitApproaching
          ? .recordingLimitWarning : handsFree ? .handsFree : .listening)
    case .transcribing, .inserting:
      show(.processing)
    case .recoverableError:
      show(.failure(snapshot.failure?.title ?? "Action needed"))
    case .ready where previousPhase == .inserting:
      let displayDuration: Duration
      switch snapshot.insertionFeedback {
      case .verified:
        show(.success)
        displayDuration = .milliseconds(700)
      case .verifiedCaptureTruncated:
        show(.captureTruncated)
        displayDuration = .milliseconds(2_000)
      case .unconfirmed:
        show(.backupCopied)
        displayDuration = .milliseconds(1_400)
      case nil:
        hide()
        return
      }
      hideTask = Task { [weak self] in
        try? await Task.sleep(for: displayDuration)
        guard !Task.isCancelled else { return }
        self?.hide()
      }
    case .setup, .preparing, .ready, .disabled:
      // A recording that ends without transcription (cancelled, too short, interrupted) would
      // otherwise vanish silently for VoiceOver users.
      if state.isRecording, unannouncedState == nil { announce("Recording stopped") }
      hide()
    }
  }

  func showLastTranscriptCopied() {
    hideTask?.cancel()
    pendingStart = nil
    show(.lastTranscriptCopied)
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  private func show(_ newState: OverlayState, announces: Bool = true) {
    if newState.isRecording, !state.isRecording { listeningStartedAt = Date() }
    if announces, newState != state || newState == unannouncedState {
      // Announce only the state title; transcript text is never spoken from the overlay.
      if let announcement = newState.announcement { announce(announcement) }
    }
    unannouncedState = announces ? nil : newState
    state = newState
    resizePanel(for: newState)
    positionPanel()
    present()
  }

  private func hide() {
    state = .hidden
    unannouncedState = nil
    dismiss()
  }

  /// Fades in quickly. A pill that is fading out comes back instead: `alphaValue` does not
  /// report a running fade's visible opacity, so the fade-in always runs, and the new
  /// generation stops the fade-out from ordering the panel out.
  private func present() {
    visibilityGeneration &+= 1
    if !panel.isVisible { panel.alphaValue = 0 }
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  private func dismiss() {
    guard panel.isVisible else { return }
    visibilityGeneration &+= 1
    let generation = visibilityGeneration
    let panel = panel
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.visibilityGeneration == generation else { return }
        panel.orderOut(nil)
      }
    }
  }

  /// Fits one line when possible, then wraps to at most two lines at the maximum width.
  private func resizePanel(for newState: OverlayState) {
    let size = Self.layout(
      hosting, state: newState, listeningStartedAt: listeningStartedAt, level: level)
    guard panel.frame.size != size else { return }
    panel.setContentSize(size)
  }

  /// Installs the overlay view in `hosting` and returns the pill size: the single-line width
  /// clamped to the minimum and maximum, and the height of up to two wrapped lines.
  static func layout(
    _ hosting: NSHostingController<OverlayView>, state: OverlayState, listeningStartedAt: Date,
    level: @escaping @Sendable () -> Float = { 0 }
  ) -> NSSize {
    hosting.rootView = OverlayView(
      state: state, listeningStartedAt: listeningStartedAt, fillsWidth: false)
    let ideal = hosting.sizeThatFits(in: CGSize(width: 10_000, height: 200))
    let width = min(max(ideal.width, minimumWidth), maximumWidth).rounded(.up)
    hosting.rootView = OverlayView(
      state: state, listeningStartedAt: listeningStartedAt, level: level)
    let height = hosting.sizeThatFits(in: CGSize(width: width, height: 200)).height.rounded(.up)
    return NSSize(width: width, height: max(height, 52))
  }

  private func positionPanel() {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main
    guard let screen else { return }
    let visible = screen.visibleFrame
    let x = max(visible.minX, visible.maxX - panel.frame.width - 16)
    let y = max(visible.minY, visible.maxY - panel.frame.height - 12)
    let origin = NSPoint(x: x.rounded(), y: y.rounded())
    guard
      abs(panel.frame.origin.x - origin.x) > 0.5
        || abs(panel.frame.origin.y - origin.y) > 0.5
    else {
      return
    }
    panel.setFrameOrigin(origin)
  }

  static func postAnnouncement(_ announcement: String) {
    VoiceOverAnnouncer.announce(announcement)
  }
}

enum OverlayState: Equatable {
  case hidden
  case listening
  case recordingLimitWarning
  case handsFree
  case processing
  case success
  case captureTruncated
  case backupCopied
  case lastTranscriptCopied
  case failure(String)

  var isRecording: Bool {
    self == .listening || self == .handsFree || self == .recordingLimitWarning
  }

  var label: String {
    switch self {
    case .hidden: ""
    case .listening: "Listening"
    case .recordingLimitWarning: "1 minute remaining"
    case .handsFree: "Hands-free"
    case .processing: "Transcribing…"
    case .success: "Inserted"
    case .captureTruncated: "Inserted captured portion"
    case .backupCopied: "Paste sent · Backup copied"
    case .lastTranscriptCopied: "Last transcript copied"
    case .failure(let title): title
    }
  }

  /// VoiceOver announcement for a state change. Processing is implied by releasing the key.
  var announcement: String? {
    switch self {
    case .hidden, .processing: nil
    case .handsFree: "Hands-free recording locked"
    case .backupCopied: "Paste sent, backup copied"
    default: label
    }
  }
}

struct OverlayView: View {
  let state: OverlayState
  let listeningStartedAt: Date
  /// Microphone loudness (RMS) while recording; drives the listening icon.
  var level: @Sendable () -> Float = { 0 }
  var fillsWidth = true

  var body: some View {
    HStack(spacing: 12) {
      icon
        .font(.system(size: 20))
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
      Text(state.label)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if fillsWidth { Spacer(minLength: 4) } else { Color.clear.frame(width: 4, height: 0) }
      if state.isRecording {
        RecordingIndicator(startedAt: listeningStartedAt)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 52)
    .background(VaniTheme.paper, in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(VaniTheme.line, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(state.label)
  }

  /// Listening and transcribing show the live mark. One view spans both, so its motion carries
  /// from the voice into the ripple; a new recording starts it fresh.
  private var markActivity: VaniMarkMotion.Activity? {
    switch state {
    case .listening, .handsFree: .listening
    case .processing: .transcribing
    default: nil
    }
  }

  @ViewBuilder
  private var icon: some View {
    if let markActivity {
      LiveVaniMark(activity: markActivity, level: level)
        .id(listeningStartedAt)
    } else {
      symbol
    }
  }

  @ViewBuilder
  private var symbol: some View {
    switch state {
    case .hidden, .listening, .handsFree, .processing:
      EmptyView()
    case .recordingLimitWarning:
      Image(systemName: "hourglass.circle.fill").foregroundStyle(VaniTheme.accent)
    case .success:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(VaniTheme.accent)
    case .captureTruncated:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.secondary)
    case .backupCopied, .lastTranscriptCopied:
      Image(systemName: "doc.on.clipboard.fill").foregroundStyle(VaniTheme.accent)
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
  }
}

/// Time since the shortcut was pressed; the recording limit counts from the same moment, give
/// or take the focus check. The live mark shows activity, so no second animation is needed.
private struct RecordingIndicator: View {
  let startedAt: Date

  var body: some View {
    TimelineView(.periodic(from: startedAt, by: 1)) { context in
      Text(Self.elapsed(from: startedAt, to: context.date))
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .accessibilityHidden(true)
  }

  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Maps microphone RMS onto the 0...1 loudness that drives the live mark.
enum LevelMeter {
  /// Speech sits roughly between -55 dBFS (quiet) and -15 dBFS (loud) at a laptop microphone.
  static func normalized(_ rms: Float) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    let decibels = 20 * log10(Double(rms))
    return min(1, max(0, (decibels + 55) / 40))
  }
}

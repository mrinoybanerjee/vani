import AppKit
import SwiftUI
import VaniCore

@MainActor
final class OverlayController {
  static let minimumWidth: CGFloat = 200
  static let maximumWidth: CGFloat = 340

  private(set) var state: OverlayState = .hidden
  private var listeningStartedAt = Date()
  private let hosting: NSHostingController<OverlayView>
  private let panel: NSPanel
  private let announce: @MainActor (String) -> Void
  private var hideTask: Task<Void, Never>?

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
      show(handsFree ? .handsFree : .listening)
    }
  }

  func update(snapshot: SessionSnapshot, previousPhase: SessionPhase) {
    hideTask?.cancel()
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
      if state.isRecording { announce("Recording stopped") }
      hide()
    }
  }

  func showLastTranscriptCopied() {
    hideTask?.cancel()
    show(.lastTranscriptCopied)
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  private func show(_ newState: OverlayState) {
    if newState != state {
      if newState.isRecording, !state.isRecording { listeningStartedAt = Date() }
      // Announce only the state title; transcript text is never spoken from the overlay.
      if let announcement = newState.announcement { announce(announcement) }
    }
    state = newState
    resizePanel(for: newState)
    positionPanel()
    panel.orderFrontRegardless()
  }

  private func hide() {
    state = .hidden
    panel.orderOut(nil)
  }

  /// Fits one line when possible, then wraps to at most two lines at the maximum width.
  private func resizePanel(for newState: OverlayState) {
    let size = Self.layout(hosting, state: newState, listeningStartedAt: listeningStartedAt)
    guard panel.frame.size != size else { return }
    panel.setContentSize(size)
  }

  /// Installs the overlay view in `hosting` and returns the pill size: the single-line width
  /// clamped to the minimum and maximum, and the height of up to two wrapped lines.
  static func layout(
    _ hosting: NSHostingController<OverlayView>, state: OverlayState, listeningStartedAt: Date
  ) -> NSSize {
    hosting.rootView = OverlayView(
      state: state, listeningStartedAt: listeningStartedAt, fillsWidth: false)
    let ideal = hosting.sizeThatFits(in: CGSize(width: 10_000, height: 200))
    let width = min(max(ideal.width, minimumWidth), maximumWidth).rounded(.up)
    hosting.rootView = OverlayView(state: state, listeningStartedAt: listeningStartedAt)
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
      } else if state == .processing {
        ProgressView()
          .controlSize(.small)
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

  @ViewBuilder
  private var icon: some View {
    switch state {
    case .hidden:
      EmptyView()
    case .listening:
      Image(systemName: "waveform.circle.fill").foregroundStyle(VaniTheme.accent)
    case .recordingLimitWarning:
      Image(systemName: "hourglass.circle.fill").foregroundStyle(VaniTheme.accent)
    case .handsFree:
      Image(systemName: "lock.circle.fill").foregroundStyle(VaniTheme.accent)
    case .processing:
      Image(systemName: "text.bubble.fill").foregroundStyle(.secondary)
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

/// A recording indicator, not a level meter: a pulsing dot and the true elapsed time.
private struct RecordingIndicator: View {
  let startedAt: Date
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(VaniTheme.accent)
        .frame(width: 8, height: 8)
        .opacity(pulsing && !reduceMotion ? 0.35 : 1)
      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        Text(Self.elapsed(from: startedAt, to: context.date))
          .font(.system(size: 12, weight: .medium).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityHidden(true)
    .onAppear { startPulse() }
    .onChange(of: reduceMotion) { startPulse() }
  }

  /// The dot pulses only while Reduce Motion is off (the opacity above stays constant when it
  /// is on, even mid-animation); the elapsed time shows recording either way.
  private func startPulse() {
    guard !reduceMotion, !pulsing else { return }
    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
      pulsing = true
    }
  }

  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

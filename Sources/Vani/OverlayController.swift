import AppKit
import SwiftUI
import VaniCore

@MainActor
final class OverlayController {
  private let model = OverlayModel()
  private let panel: NSPanel
  private var hideTask: Task<Void, Never>?

  init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 252, height: 54),
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
    panel.contentView = NSHostingView(rootView: OverlayView(model: model))
  }

  func update(snapshot: SessionSnapshot, previousPhase: SessionPhase) {
    hideTask?.cancel()
    switch snapshot.phase {
    case .listening:
      show(.listening)
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

  private func show(_ state: OverlayState) {
    model.state = state
    positionPanel()
    panel.orderFrontRegardless()
  }

  private func hide() {
    model.state = .hidden
    panel.orderOut(nil)
  }

  private func positionPanel() {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main
    guard let screen else { return }
    let visible = screen.visibleFrame
    let x = visible.midX - panel.frame.width / 2
    let y = visible.minY + 24
    panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
  }
}

private enum OverlayState: Equatable {
  case hidden
  case listening
  case processing
  case success
  case backupCopied
  case lastTranscriptCopied
  case failure(String)
}

@MainActor
private final class OverlayModel: ObservableObject {
  @Published var state: OverlayState = .hidden
}

private struct OverlayView: View {
  @ObservedObject var model: OverlayModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 12) {
      icon
        .frame(width: 28, height: 28)
      Text(label)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 4)
      if model.state == .listening {
        WaveformBars(animated: !reduceMotion)
          .frame(width: 44, height: 22)
      } else if model.state == .processing {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .frame(width: 252, height: 54)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private var icon: some View {
    switch model.state {
    case .hidden:
      EmptyView()
    case .listening:
      Image(systemName: "waveform.circle.fill").foregroundStyle(.teal)
    case .processing:
      Image(systemName: "text.bubble.fill").foregroundStyle(.blue)
    case .success:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .backupCopied:
      Image(systemName: "clipboard.fill").foregroundStyle(.blue)
    case .lastTranscriptCopied:
      Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.teal)
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
  }

  private var label: String {
    switch model.state {
    case .hidden: ""
    case .listening: "Listening"
    case .processing: "Writing"
    case .success: "Inserted"
    case .backupCopied: "Paste sent - backup copied"
    case .lastTranscriptCopied: "Last transcript copied"
    case .failure(let message): message
    }
  }
}

private struct WaveformBars: View {
  let animated: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 15, paused: !animated)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      HStack(alignment: .center, spacing: 3) {
        ForEach(0..<5, id: \.self) { index in
          let wave = sin(time * 7 + Double(index) * 0.9)
          Capsule()
            .fill(.teal)
            .frame(width: 4, height: animated ? 8 + abs(wave) * 13 : 12)
        }
      }
      .frame(maxHeight: .infinity)
    }
  }
}

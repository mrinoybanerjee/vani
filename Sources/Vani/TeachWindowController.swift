import AppKit
import Combine
import SwiftUI
import VaniCore

private enum TeachWindowMetrics {
  static let width: CGFloat = 520
  static let height: CGFloat = 270
}

enum TeachQAWindowFixture {
  static let candidate = CorrectionCandidate(
    rawTranscript: "Vanny learns locally",
    recognizedTranscript: "Vanny learns locally",
    finalTranscript: "Vanny learns locally",
    applicationBundleIdentifier: "com.mrinoy.vani.qa"
  )

  static func save(_ corrected: String) async -> Bool {
    true
  }
}

@MainActor
final class TeachVaniViewModel: ObservableObject {
  let original: String
  @Published var corrected: String
  @Published private(set) var isSaving = false
  @Published private(set) var saveFailed = false

  init(original: String) {
    self.original = original
    corrected = original
  }

  var canSave: Bool {
    !isSaving
      && corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        != original.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func commit(
    save: @MainActor (String) async -> Bool,
    dismiss: () -> Void
  ) async {
    guard canSave else { return }
    isSaving = true
    saveFailed = false
    defer { isSaving = false }
    if await save(corrected) {
      dismiss()
    } else {
      saveFailed = true
    }
  }
}

@MainActor
final class TeachWindowController: NSObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private let activateApplication: () -> Void
  private var activationObserver: NSObjectProtocol?
  /// Set when Teach asks macOS to activate Vani; the next activation refocuses Teach once.
  private var activationRequestedAt: Date?
  private let focusRequests = PassthroughSubject<Void, Never>()
  static let activationRequestLifetime: TimeInterval = 5

  init(
    activateApplication: @escaping () -> Void = {
      NSApplication.shared.activate()
    }
  ) {
    self.activateApplication = activateApplication
  }

  func present(candidate: CorrectionCandidate, coordinator: AppCoordinator) {
    present(
      candidate: candidate,
      save: { [weak coordinator] corrected in
        guard let coordinator else { return false }
        return await coordinator.learnCorrection(
          original: candidate.transcript,
          corrected: corrected,
          applicationBundleIdentifier: candidate.applicationBundleIdentifier
        )
      }
    )
  }

  func present(
    candidate: CorrectionCandidate,
    save: @escaping @MainActor (String) async -> Bool
  ) {
    let content = TeachVaniView(
      candidate: candidate,
      dismiss: { [weak self] in self?.dismiss() },
      save: save,
      focusRequests: focusRequests.eraseToAnyPublisher()
    )
    present(rootView: content)
  }

  func requestActivation() {
    activationRequestedAt = Date()
    activateApplication()
  }

  /// True once for a recent activation that Teach requested. Other activations (for example,
  /// the user switching back to the workspace window) must not steal focus.
  private func consumeActivationRequest() -> Bool {
    guard let requested = activationRequestedAt else { return false }
    activationRequestedAt = nil
    return Date().timeIntervalSince(requested) < Self.activationRequestLifetime
  }

  func present<Content: View>(rootView: Content) {
    if let window {
      window.orderFrontRegardless()
      requestActivation()
      window.makeKeyAndOrderFront(nil)
      return
    }

    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: TeachWindowMetrics.width,
        height: TeachWindowMetrics.height
      ),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Teach Vani"
    window.contentViewController = hostingController
    hostingController.view.layoutSubtreeIfNeeded()
    let fittingSize = hostingController.view.fittingSize
    window.setContentSize(
      NSSize(
        width: max(TeachWindowMetrics.width, fittingSize.width),
        height: max(TeachWindowMetrics.height, fittingSize.height)
      )
    )
    window.contentMinSize = NSSize(
      width: TeachWindowMetrics.width,
      height: TeachWindowMetrics.height
    )
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window

    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self, weak window] _ in
      Task { @MainActor in
        guard let self, let window, self.window === window else { return }
        guard self.consumeActivationRequest() || window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        self.focusRequests.send()
      }
    }

    window.orderFrontRegardless()
    requestActivation()
    window.makeKeyAndOrderFront(nil)
    Task { @MainActor in
      await Task.yield()
      guard self.window === window else { return }
      window.makeKeyAndOrderFront(nil)
    }
  }

  func dismiss() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
      return
    }
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
      self.activationObserver = nil
    }
    activationRequestedAt = nil
    closingWindow.contentViewController = nil
    window = nil
  }
}

struct TeachVaniView: View {
  let dismiss: () -> Void
  let save: @MainActor (String) async -> Bool
  let focusRequests: AnyPublisher<Void, Never>
  @StateObject private var model: TeachVaniViewModel
  @FocusState private var editorFocused: Bool

  init(
    candidate: CorrectionCandidate,
    dismiss: @escaping () -> Void,
    save: @escaping @MainActor (String) async -> Bool,
    focusRequests: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
  ) {
    self.dismiss = dismiss
    self.save = save
    self.focusRequests = focusRequests
    _model = StateObject(wrappedValue: TeachVaniViewModel(original: candidate.transcript))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Correct dictation")
        .font(.system(size: 26, weight: .regular, design: .serif))
        .accessibilityAddTraits(.isHeader)
      Text("Fix only what Vani got wrong. Vani saves the correction on this Mac.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      TextEditor(text: $model.corrected)
        .font(.system(size: 15))
        .lineSpacing(5)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 150)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .focused($editorFocused)
        .disabled(model.isSaving)
        .accessibilityLabel("Corrected transcript")
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.quaternary, lineWidth: 1)
            .allowsHitTesting(false)
        }
      if model.saveFailed {
        Label(
          "The correction wasn’t saved. Your edit is still here; try again.",
          systemImage: "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      }
      Text("Text already inserted in another app stays as it is.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        if model.isSaving {
          ProgressView().controlSize(.small).accessibilityHidden(true)
          Text("Saving correction…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", action: dismiss)
          .disabled(model.isSaving)
          .keyboardShortcut(.cancelAction)
        Button("Save Learning") {
          Task {
            await model.commit(save: save) {
              // The window closes on success, so VoiceOver would otherwise hear nothing.
              VoiceOverAnnouncer.announce("Correction saved")
              dismiss()
            }
            if model.saveFailed { VoiceOverAnnouncer.announce("Correction not saved") }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
        .keyboardShortcut("s", modifiers: .command)
      }
    }
    .padding(24)
    .tint(VaniTheme.accent)
    .frame(minWidth: TeachWindowMetrics.width, maxWidth: .infinity, maxHeight: .infinity)
    .background(VaniTheme.paper)
    .task {
      await Task.yield()
      editorFocused = true
    }
    .onReceive(focusRequests) { _ in
      editorFocused = true
    }
  }
}

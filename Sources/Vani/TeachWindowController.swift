import AppKit
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
      save: save
    )
    present(rootView: content)
  }

  func requestActivation() {
    activateApplication()
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
        window.makeKeyAndOrderFront(nil)
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
    closingWindow.contentViewController = nil
    window = nil
  }
}

struct TeachVaniView: View {
  let dismiss: () -> Void
  let save: @MainActor (String) async -> Bool
  @StateObject private var model: TeachVaniViewModel
  @FocusState private var editorFocused: Bool

  init(
    candidate: CorrectionCandidate,
    dismiss: @escaping () -> Void,
    save: @escaping @MainActor (String) async -> Bool
  ) {
    self.dismiss = dismiss
    self.save = save
    _model = StateObject(wrappedValue: TeachVaniViewModel(original: candidate.transcript))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Correct your transcript", systemImage: "text.badge.checkmark")
        .font(.headline)
      Text("Fix only what Vani got wrong. The correction is saved locally for future dictation.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      TextEditor(text: $model.corrected)
        .font(.body)
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
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      }
      Text("Text already inserted in another app stays as it is.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        if model.isSaving {
          ProgressView().controlSize(.small)
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
            await model.commit(save: save, dismiss: dismiss)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
        .keyboardShortcut("s", modifiers: .command)
      }
    }
    .padding(20)
    .frame(minWidth: TeachWindowMetrics.width, maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      await Task.yield()
      editorFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      editorFocused = true
    }
  }
}

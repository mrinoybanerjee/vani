import AppKit
import SwiftUI
import Testing
import VaniCore

@testable import Vani

@MainActor
private final class EditorModel: ObservableObject {
  @Published var text = "Vanny learns locally"
}

private struct EditorHarness: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    TextEditor(text: $model.text)
  }
}

extension NativeInteractionTests {
  @Suite(.serialized) @MainActor
  struct TeachWindowControllerTests {
    @Test
    func activatesAndPresentsAKeyCapableEditorWindow() {
      var didActivate = false
      let controller = TeachWindowController {
        didActivate = true
      }

      controller.present(rootView: Text("Editor"))

      #expect(didActivate)
      #expect(controller.window?.title == "Teach Vani")
      #expect(controller.window?.isVisible == true)
      #expect(controller.window?.canBecomeKey == true)
      #expect(controller.window?.styleMask.contains(.resizable) == true)
      #expect((controller.window?.contentView?.frame.width ?? 0) >= 520)
      #expect((controller.window?.contentView?.frame.height ?? 0) >= 270)

      controller.dismiss()
      #expect(controller.window == nil)
    }

    @Test
    func productionTeachEditorReceivesFocusAndAcceptsInput() async {
      let candidate = CorrectionCandidate(
        rawTranscript: "Vanny learns locally",
        recognizedTranscript: "Vanny learns locally",
        finalTranscript: "Vanny learns locally",
        applicationBundleIdentifier: "com.mrinoy.vani.tests"
      )
      let controller = TeachWindowController(activateApplication: {})
      controller.present(candidate: candidate, save: { _ in true })

      let editorFocused = await waitUntil { controller.window?.firstResponder is NSTextView }
      #expect(editorFocused)
      let editor = controller.window?.firstResponder as? NSTextView
      #expect(editor?.isEditable == true)
      #expect(editor?.isSelectable == true)

      editor?.selectAll(nil)
      editor?.insertText(
        "Vani learns locally",
        replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0)
      )
      let editorUpdated = await waitUntil { editor?.string == "Vani learns locally" }
      #expect(editorUpdated)

      controller.dismiss()
    }

    @Test
    func productionTeachEditorExpandsWithItsWindow() async throws {
      let controller = TeachWindowController(activateApplication: {})
      controller.present(candidate: TeachQAWindowFixture.candidate, save: { _ in true })
      defer { controller.dismiss() }
      let editorAppeared = await waitUntil {
        controller.window?.contentView.flatMap(findTextView) != nil
      }
      #expect(editorAppeared)
      let window = try #require(controller.window)
      let editor = try #require(window.contentView.flatMap(findTextView))
      let initialWidth = editor.frame.width
      window.setContentSize(NSSize(width: 780, height: 540))
      let editorExpanded = await waitUntil { editor.frame.width > initialWidth + 100 }
      #expect(editorExpanded)
      #expect(editor.frame.height > 150)

      if let directory = ProcessInfo.processInfo.environment["VANI_UI_SNAPSHOT_DIR"] {
        window.setContentSize(NSSize(width: 560, height: 360))
        let editorContracted = await waitUntil { editor.frame.width < 560 }
        #expect(editorContracted)
        let content = try #require(window.contentView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
          window.appearance = NSAppearance(named: appearance)
          await Task.yield()
          content.layoutSubtreeIfNeeded()
          content.displayIfNeeded()
          let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
          content.cacheDisplay(in: content.bounds, to: bitmap)
          let data = try #require(bitmap.representation(using: .png, properties: [:]))
          let folder = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try data.write(to: folder.appendingPathComponent("teach-\(appearance.rawValue).png"))
        }
      }
    }

    @Test
    func textEditorBindingReceivesNativeInput() async {
      let model = EditorModel()
      let controller = TeachWindowController(activateApplication: {})
      controller.present(rootView: EditorHarness(model: model))

      let editorAppeared = await waitUntil {
        controller.window?.contentView.flatMap(findTextView) != nil
      }
      #expect(editorAppeared)
      let editor = controller.window?.contentView.flatMap(findTextView)
      #expect(controller.window?.makeFirstResponder(editor) == true)

      editor?.selectAll(nil)
      editor?.insertText(
        "Vani learns locally",
        replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0)
      )
      let bindingUpdated = await waitUntil { model.text == "Vani learns locally" }
      #expect(bindingUpdated)

      controller.dismiss()
    }

    @Test
    func repeatedPresentationPreservesTheExistingEditor() async {
      let controller = TeachWindowController(activateApplication: {})
      controller.present(rootView: Text("First"))
      let firstWindow = controller.window

      controller.present(rootView: Text("Second"))
      let secondWindow = controller.window
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

      #expect(secondWindow === firstWindow)
      let secondWindowVisible = await waitUntil { secondWindow?.isVisible == true }
      #expect(secondWindowVisible)

      controller.dismiss()
      #expect(controller.window == nil)
    }

    @Test
    func activationNotificationRefrontsTheTeachWindow() async {
      let controller = TeachWindowController(activateApplication: {})
      controller.present(rootView: Text("Editor"))
      controller.window?.orderOut(nil)
      #expect(controller.window?.isVisible == false)

      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

      let windowVisible = await waitUntil { controller.window?.isVisible == true }
      #expect(windowVisible)
      controller.dismiss()
    }

    @Test
    func unrequestedActivationDoesNotStealFocusFromOtherWindows() async {
      let controller = TeachWindowController(activateApplication: {})
      controller.present(rootView: Text("Editor"))
      defer { controller.dismiss() }
      // The activation Teach requested is honoured once.
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      try? await Task.sleep(for: .milliseconds(50))
      #expect(controller.window?.isVisible == true)

      // Later activations (for example, returning to the workspace) leave Teach alone.
      controller.window?.orderOut(nil)
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      let refronted = await waitUntil(timeout: 0.3) { controller.window?.isVisible == true }
      #expect(!refronted)

      // A new explicit request re-arms the one-shot focus.
      controller.requestActivation()
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      let requested = await waitUntil { controller.window?.isVisible == true }
      #expect(requested)
    }

    @Test
    func closedTeachWindowCanBePresentedAgain() {
      let controller = TeachWindowController(activateApplication: {})
      controller.present(rootView: Text("First"))
      let firstWindow = controller.window
      controller.dismiss()

      controller.present(rootView: Text("Second"))

      #expect(controller.window !== firstWindow)
      #expect(controller.window?.isVisible == true)
      controller.dismiss()
    }

    @Test
    func teachViewModelEnablesSaveOnlyForMeaningfulEdits() {
      let model = TeachVaniViewModel(original: "Vanny learns locally")
      #expect(model.canSave == false)

      model.corrected = "  Vanny learns locally\n"
      #expect(model.canSave == false)

      model.corrected = "Vani learns locally"
      #expect(model.canSave == true)
    }

    @Test
    func teachViewModelDismissesOnlyAfterSuccessfulSave() async {
      let model = TeachVaniViewModel(original: "Vanny learns locally")
      model.corrected = "Vani learns locally"
      var dismissed = false
      var savedText: String?

      await model.commit(
        save: { corrected in
          savedText = corrected
          return false
        },
        dismiss: { dismissed = true }
      )
      #expect(savedText == "Vani learns locally")
      #expect(dismissed == false)
      #expect(model.saveFailed == true)
      #expect(model.corrected == "Vani learns locally")
      #expect(model.canSave == true)

      await model.commit(
        save: { _ in true },
        dismiss: { dismissed = true }
      )
      #expect(dismissed == true)
      #expect(model.saveFailed == false)
    }

    @Test
    func teachViewModelAllowsOnlyOneSaveAtATime() async {
      let model = TeachVaniViewModel(original: "Vanny learns locally")
      model.corrected = "Vani learns locally"
      var saveCalls = 0
      var firstSaveContinuation: CheckedContinuation<Bool, Never>?

      let firstCommit = Task { @MainActor in
        await model.commit(
          save: { _ in
            saveCalls += 1
            return await withCheckedContinuation { continuation in
              firstSaveContinuation = continuation
            }
          },
          dismiss: {}
        )
      }
      let firstSaveStarted = await waitUntil { firstSaveContinuation != nil }
      #expect(firstSaveStarted)
      #expect(model.isSaving == true)
      #expect(model.canSave == false)

      await model.commit(
        save: { _ in
          saveCalls += 1
          return true
        },
        dismiss: {}
      )
      #expect(saveCalls == 1)

      firstSaveContinuation?.resume(returning: true)
      await firstCommit.value
      #expect(model.isSaving == false)
      #expect(model.canSave == true)
    }

    @Test
    func teachQAWindowFixtureNeverPersists() async {
      #expect(TeachQAWindowFixture.candidate.transcript == "Vanny learns locally")
      #expect(TeachQAWindowFixture.candidate.applicationBundleIdentifier == "com.mrinoy.vani.qa")
      #expect(await TeachQAWindowFixture.save("Vani learns locally"))
    }

    @Test
    func qaWindowLaunchGatePresentsOnceAfterBothLifecycleEvents() {
      var presentations = 0
      let gate = QAWindowLaunchGate(isRequested: true) {
        presentations += 1
      }

      gate.markCoordinatorReady()
      #expect(presentations == 0)
      gate.markApplicationReady()
      #expect(presentations == 1)
      gate.markApplicationReady()
      gate.markCoordinatorReady()
      #expect(presentations == 1)
    }

    @Test
    func qaWindowLaunchGateSupportsApplicationReadyFirst() {
      var presentations = 0
      let gate = QAWindowLaunchGate(isRequested: true) {
        presentations += 1
      }

      gate.markApplicationReady()
      #expect(presentations == 0)
      gate.markCoordinatorReady()
      #expect(presentations == 1)
      gate.markApplicationReady()
      gate.markCoordinatorReady()
      #expect(presentations == 1)
    }

    @Test
    func qaWindowLaunchGateDoesNothingWhenNotRequested() {
      var presentations = 0
      let gate = QAWindowLaunchGate(isRequested: false) {
        presentations += 1
      }

      gate.markApplicationReady()
      gate.markCoordinatorReady()

      #expect(presentations == 0)
    }

    @Test(arguments: [
      ("1", QAWindowMode.menu),
      ("settings", QAWindowMode.settings),
      ("teach", QAWindowMode.teach),
    ])
    func qaWindowModeRoutesSupportedValues(value: String, expected: QAWindowMode) {
      #expect(QAWindowMode(environmentValue: value) == expected)
    }

    @Test(arguments: [String?.none, "", "unknown"])
    func qaWindowModeRejectsUnsupportedValues(value: String?) {
      #expect(QAWindowMode(environmentValue: value) == nil)
    }
  }

}

@MainActor
private func findTextView(in view: NSView) -> NSTextView? {
  if let textView = view as? NSTextView {
    return textView
  }
  for subview in view.subviews {
    if let textView = findTextView(in: subview) {
      return textView
    }
  }
  return nil
}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 1,
  condition: () -> Bool
) async -> Bool {
  let deadline = Date(timeIntervalSinceNow: timeout)
  while !condition(), Date() < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

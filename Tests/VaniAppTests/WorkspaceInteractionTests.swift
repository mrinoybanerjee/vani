import AppKit
import SwiftUI
import Testing
import VaniCore

@testable import Vani

extension NativeInteractionTests {
  @Suite(.serialized) @MainActor
  struct WorkspaceInteractionTests {
    @Test func oneWindowPreservesSettingsDraftAndRoutesOnlyVisibleShortcuts() async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let notes = NotesModel(store: NoteStore(directory: directory.appendingPathComponent("Notes")))
      let meetings = MeetingModel(
        store: MeetingStore(directory: directory.appendingPathComponent("Meetings")),
        recognizer: FluidAudioSpeechRecognizer(), reserveSpeech: { false }, releaseSpeech: {})
      let model = WorkspaceModel(notes: notes, meetings: meetings)
      let coordinator = AppCoordinator(startAutomatically: false)
      let controller = WorkspaceWindowController(model: model)
      #expect(await model.select(.settings))
      controller.present(coordinator: coordinator)
      let window = try #require(controller.window)
      defer { window.close() }
      let content = try #require(window.contentView)
      await waitUntil {
        self.descendants(content, NSSegmentedControl.self).contains { $0.segmentCount == 5 }
      }
      let settingsPicker = try #require(
        descendants(content, NSSegmentedControl.self).first { $0.segmentCount == 5 })
      settingsPicker.selectedSegment = 1
      settingsPicker.sendAction(settingsPicker.action, to: settingsPicker.target)
      func spokenField() -> NSTextField? {
        descendants(content, NSTextField.self).first { $0.placeholderString == "Spoken phrase" }
      }
      await waitUntil { spokenField()?.isEnabled == true }
      let field = try #require(spokenField())
      #expect(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.insertText("A draft to keep", replacementRange: editor.selectedRange())
      window.makeFirstResponder(nil)
      settingsPicker.selectedSegment = 2
      settingsPicker.sendAction(settingsPicker.action, to: settingsPicker.target)
      func snippetField() -> NSTextField? {
        descendants(content, NSTextField.self).first { $0.placeholderString == "Voice trigger" }
      }
      await waitUntil { snippetField()?.isEnabled == true }
      #expect(spokenField() == nil)
      let trigger = try #require(snippetField())
      #expect(window.makeFirstResponder(trigger))
      let triggerEditor = try #require(trigger.currentEditor() as? NSTextView)
      triggerEditor.insertText("Keep this snippet", replacementRange: triggerEditor.selectedRange())
      window.makeFirstResponder(nil)

      #expect(await model.select(.notes))
      controller.present(coordinator: coordinator)
      #expect(controller.window === window)
      await waitUntil { snippetField()?.isEnabled == false }
      await waitUntil {
        self.descendants(content, NSTextField.self).contains {
          $0.placeholderString == "Search notes" && $0.isEnabled
        }
      }
      content.layoutSubtreeIfNeeded()
      let newNote = try command("n", code: 45, window: window)
      #expect(window.performKeyEquivalent(with: newNote))
      await waitUntil { notes.notes.count == 1 && !notes.busy }
      #expect(notes.notes.count == 1)
      notes.draft?.text = "Saved with Command-S"
      content.layoutSubtreeIfNeeded()
      #expect(window.performKeyEquivalent(with: try command("s", code: 1, window: window)))
      await waitUntil { !notes.dirty && !notes.busy }
      #expect(notes.notes.first?.text == "Saved with Command-S")
      notes.draft?.text = "Saved when leaving Notes"
      #expect(await model.select(.settings))
      await waitUntil { snippetField()?.isEnabled == true }
      #expect(snippetField()?.stringValue == "Keep this snippet")
      settingsPicker.selectedSegment = 1
      settingsPicker.sendAction(settingsPicker.action, to: settingsPicker.target)
      await waitUntil { spokenField()?.isEnabled == true }
      #expect(spokenField()?.stringValue == "A draft to keep")
      #expect(snippetField() == nil)
      #expect(notes.notes.first?.text == "Saved when leaving Notes")
      #expect(!window.performKeyEquivalent(with: newNote))
      #expect(notes.notes.count == 1)

      #expect(await model.select(.meetings))
      controller.present(coordinator: coordinator)
      #expect(controller.window === window)
      #expect(await model.prepareToClose())
      window.close()
      controller.present(coordinator: coordinator)
      #expect(controller.window === window)
      #expect(window.isVisible)
      #expect(await model.select(.settings))
      await waitUntil { spokenField()?.isEnabled == true }
      #expect(spokenField()?.stringValue == "A draft to keep")
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
      (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func command(_ character: String, code: UInt16, window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    private func waitUntil(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(3)
      while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
  }

}

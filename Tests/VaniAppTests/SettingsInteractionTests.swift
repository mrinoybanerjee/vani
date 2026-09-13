import AppKit
import SwiftUI
import Testing

@testable import Vani

extension NativeInteractionTests {
  @Suite(.serialized) @MainActor
  struct SettingsInteractionTests {
    @Test func dictionaryDraftSurvivesSwitchingVocabularySections() async throws {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: SettingsView().environmentObject(
          AppCoordinator(startAutomatically: false)))
      window.orderFront(nil)
      defer { window.close() }
      let content = try #require(window.contentView)
      func spokenField() -> NSTextField? {
        descendants(in: content, of: NSTextField.self).first {
          $0.placeholderString == "Spoken phrase"
        }
      }
      await waitUntil {
        self.descendants(in: content, of: NSSegmentedControl.self).contains { $0.segmentCount == 5 }
      }
      let settingsPicker = try #require(
        descendants(in: content, of: NSSegmentedControl.self).first { $0.segmentCount == 5 })
      settingsPicker.selectedSegment = 1
      settingsPicker.sendAction(settingsPicker.action, to: settingsPicker.target)
      await waitUntil { spokenField() != nil }
      let field = try #require(spokenField())
      #expect(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.insertText("Keep this draft", replacementRange: editor.selectedRange())
      window.makeFirstResponder(nil)
      #expect(field.stringValue == "Keep this draft")

      let picker = try #require(
        descendants(in: content, of: NSSegmentedControl.self).first { $0.segmentCount == 2 })
      picker.selectedSegment = 1
      picker.sendAction(picker.action, to: picker.target)
      await waitUntil { spokenField() == nil }
      #expect(spokenField() == nil)
      picker.selectedSegment = 0
      picker.sendAction(picker.action, to: picker.target)
      await waitUntil { spokenField() != nil }
      let restored = try #require(spokenField())
      #expect(restored.stringValue == "Keep this draft")
    }

    private func descendants<T: NSView>(in view: NSView, of type: T.Type) -> [T] {
      (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0, of: type) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(2)
      while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
  }

}

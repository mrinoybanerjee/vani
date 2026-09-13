import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
  let model: NotesModel
  private(set) var window: NSWindow?
  private var closing = false

  init(model: NotesModel = NotesModel()) { self.model = model }

  func present(load: Bool = true) {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = "Vani Notes"
      window.contentMinSize = NSSize(width: 720, height: 480)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = NSHostingController(rootView: NotesView(model: model))
      window.setContentSize(NSSize(width: 980, height: 680))
      window.center()
      self.window = window
    }
    NSApplication.shared.activate()
    window?.makeKeyAndOrderFront(nil)
    if load { Task { await model.load() } }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closing else { return false }
    guard model.dirty || model.busy else { return true }
    closing = true
    Task {
      if await model.save() { sender.close() }
      closing = false
    }
    return false
  }
}

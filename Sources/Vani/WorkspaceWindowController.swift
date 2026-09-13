import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
  let model: WorkspaceModel
  private(set) var window: NSWindow?
  private var closing = false

  init(model: WorkspaceModel) { self.model = model }

  func present(coordinator: AppCoordinator) {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false)
      window.title = "Vani"
      window.contentMinSize = NSSize(width: 820, height: 560)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = NSHostingController(
        rootView: WorkspaceView(model: model).environmentObject(coordinator))
      window.setContentSize(NSSize(width: 1060, height: 720))
      window.center()
      window.setFrameAutosaveName("VaniWorkspace")
      self.window = window
    }
    NSApplication.shared.activate()
    window?.deminiaturize(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closing else { return false }
    sender.makeFirstResponder(nil)
    closing = true
    Task {
      if await model.prepareToClose() { sender.close() }
      closing = false
    }
    return false
  }
}

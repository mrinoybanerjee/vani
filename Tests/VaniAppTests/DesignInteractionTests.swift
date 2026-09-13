import AppKit
import SwiftUI
import Testing
import VaniCore

@testable import Vani

extension NotesTests {
  @Test func notebookKeyboardCreationAndSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = NotesModel(store: NoteStore(directory: directory))
    await model.load()
    let controller = await makeNotesWorkspace(model: model, directory: directory)
    let window = try #require(controller.window)
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let newNote = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false,
        keyCode: 45))
    #expect(window.performKeyEquivalent(with: newNote))
    for _ in 0..<50 {
      if model.draft != nil && !model.busy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.notes.count == 1)
    let search = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false,
        keyCode: 3))
    #expect(window.performKeyEquivalent(with: search))
    func searchField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.placeholderString == "Search notes" {
        return field
      }
      return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
    let content = try #require(window.contentView)
    let field = try #require(searchField(in: content))
    for _ in 0..<50 {
      if field.currentEditor() === window.firstResponder { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let editor = try #require(field.currentEditor())
    #expect(editor === window.firstResponder)
  }

  @Test func captureDesignStatesWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["VANI_UI_SNAPSHOT_DIR"] else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = NotesModel(store: NoteStore(directory: directory))
    await model.create(text: "An idea worth keeping\n\nMake more space for the work that matters.")
    await model.create(
      text:
        "A quieter morning\n\nLeave the first hour open. Read a few pages, take a walk, and let the day find its rhythm."
    )
    await model.create(
      text:
        "Thoughts for tomorrow\n\nThe best tools make a little room for us to think.\n\nKeep the experience simple. Make the next step obvious. Let every word have a purpose."
    )
    model.draft?.title = "Thoughts for tomorrow"
    model.draft?.text =
      "The best tools make a little room for us to think.\n\nKeep the experience simple. Make the next step obvious. Let every word have a purpose.\n\nA few things to explore\n\n• A calmer start to the day\n• Less switching, more focus\n• A place for ideas to grow"
    await model.save()
    let controller = await makeNotesWorkspace(model: model, directory: directory)
    let window = try #require(controller.window)
    defer { window.close() }
    try await capture(window, name: "notebook", path: path)
    window.setContentSize(NSSize(width: 820, height: 560))
    try await capture(window, name: "notebook-compact", path: path)
    window.setContentSize(NSSize(width: 1060, height: 720))
    await model.select(nil)
    try await capture(window, name: "notebook-empty", path: path)
    await model.select(model.notes.first)
    model.draft?.text = "An unsaved thought"
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("notes.json"))
    await model.save()
    try await capture(window, name: "notebook-error", path: path)

    model.discardChanges()
    #expect(await controller.model.select(.settings))
    try await capture(window, name: "settings", path: path)
    let coordinator = AppCoordinator(startAutomatically: false)
    let menu = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 450),
      styleMask: [.titled], backing: .buffered, defer: false)
    menu.isReleasedWhenClosed = false
    menu.contentViewController = NSHostingController(
      rootView: MenuContentView().environmentObject(coordinator))
    menu.orderFront(nil)
    defer { menu.close() }
    try await capture(menu, name: "setup", path: path)
  }

  @Test func meetingDesignAndNativeNotesWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["VANI_UI_SNAPSHOT_DIR"] else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = MeetingRecord(title: "A simpler way forward")
    meeting.endedAt = Date()
    meeting.notes =
      "A few thoughts from our conversation\n\nKeep the first experience focused. We only need one clear next step.\n\n• Share the prototype on Friday\n• Keep the current keyboard shortcut\n• Make room for a little more clarity"
    meeting.transcript = [
      .init(
        id: UUID(), source: .microphone, offset: 0, duration: 20,
        text: "Let’s keep the first experience focused. We only need one clear next step."),
      .init(
        id: UUID(), source: .system, offset: 20, duration: 20,
        text: "Agreed. I will share the prototype on Friday. Keep the current keyboard shortcut."),
    ]
    meeting.summary =
      "Summary\nA focused first experience, with one clear next step.\n\nDecisions\nKeep the current keyboard shortcut. [0:20]\n  Source: “Keep the current keyboard shortcut.”\n\nAction items\nShare the prototype on Friday. [0:20]\n  Source: “I will share the prototype on Friday.”"
    try await store.save(meeting)
    let model = MeetingModel(
      store: store, recognizer: NotesUITestRecognizer(), reserveSpeech: { false },
      releaseSpeech: {})
    await model.load()
    let workspace = WorkspaceModel(
      notes: NotesModel(store: NoteStore(directory: directory.appendingPathComponent("Notes"))),
      meetings: model)
    let controller = WorkspaceWindowController(model: workspace)
    controller.present(coordinator: AppCoordinator(startAutomatically: false))
    let window = try #require(controller.window)
    defer { window.close() }
    try await capture(window, name: "meetings-empty", path: path)
    await model.select(meeting)
    let content = try #require(window.contentView)
    func meetingPicker(in view: NSView) -> NSSegmentedControl? {
      if let picker = view as? NSSegmentedControl,
        picker.segmentCount == 3, picker.label(forSegment: 0) == "My notes"
      {
        return picker
      }
      return view.subviews.lazy.compactMap { meetingPicker(in: $0) }.first
    }
    for _ in 0..<50 {
      if meetingPicker(in: content) != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let notesTab = try #require(meetingPicker(in: content))
    notesTab.selectedSegment = 0
    notesTab.sendAction(notesTab.action, to: notesTab.target)
    try await capture(window, name: "meeting-notes", path: path)
    window.setContentSize(NSSize(width: 820, height: 560))
    try await capture(window, name: "meeting-compact", path: path)
    window.setContentSize(NSSize(width: 1060, height: 720))
    func editor(in view: NSView) -> NSTextView? {
      guard !view.isHiddenOrHasHiddenAncestor else { return nil }
      if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
      return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    let nativeEditor = try #require(editor(in: content))
    window.makeFirstResponder(nativeEditor)
    nativeEditor.selectAll(nil)
    nativeEditor.insertText(
      "My live notes stay mine.", replacementRange: NSRange(location: NSNotFound, length: 0))
    for _ in 0..<50 {
      if model.draft?.notes == "My live notes stay mine." { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.draft?.notes == "My live notes stay mine.")
    #expect(await model.prepareToClose())
    #expect(try await store.load().first?.notes == "My live notes stay mine.")
    #expect(model.draft?.summary == meeting.summary)
  }

  private func capture(_ window: NSWindow, name: String, path: String) async throws {
    let folder = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: appearance)
      try await Task.sleep(for: .milliseconds(150))
      let content = try #require(window.contentView)
      content.layoutSubtreeIfNeeded()
      content.displayIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: folder.appendingPathComponent("\(name)-\(appearance.rawValue).png"))
    }
  }
}

import AppKit
import Foundation
import Testing
import VaniCore

@testable import Vani

actor NotesUITestRecognizer: SpeechRecognizing {
  func modelsAreInstalled() -> Bool { false }
  func prepare(progress: @escaping @Sendable (Double) -> Void) {}
  func transcribe(_ audio: CapturedAudio) throws -> SpeechResult {
    throw MeetingError.capture("Recording is disabled in this UI fixture")
  }
}

@Suite(.serialized) @MainActor
struct NotesTests {
  func makeNotesWorkspace(model: NotesModel, directory: URL) async -> WorkspaceWindowController {
    let meetings = MeetingModel(
      store: MeetingStore(directory: directory.appendingPathComponent("Meetings")),
      recognizer: NotesUITestRecognizer(), reserveSpeech: { false }, releaseSpeech: {})
    let workspace = WorkspaceModel(notes: model, meetings: meetings)
    #expect(await workspace.select(.notes))
    let controller = WorkspaceWindowController(model: workspace)
    controller.present(coordinator: AppCoordinator(startAutomatically: false))
    return controller
  }

  private func fixture() -> (URL, NotesModel) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (directory, NotesModel(store: NoteStore(directory: directory)))
  }

  @Test func createEditSearchSwitchAndReopen() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "First thought")
    let first = try #require(model.draft)
    model.draft?.text = "An edited thought about tomorrow"
    await model.create(text: "Second thought")
    #expect(model.notes.count == 2)
    #expect(model.notes.first { $0.id == first.id }?.text.contains("tomorrow") == true)
    model.search = "TOMORROW"
    #expect(model.visibleNotes.map(\.id) == [first.id])
    let reopened = NotesModel(store: NoteStore(directory: directory))
    await reopened.load()
    #expect(reopened.notes == model.notes)
    await model.select(first)
    #expect(model.draft?.text.contains("tomorrow") == true)
    #expect(!model.dirty)
  }

  @Test func failedSaveRetainsDraftAndBlocksSwitch() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Keep this")
    model.draft?.text = "Unwritten text"
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("notes.json"))
    await model.select(nil)
    #expect(model.draft?.text == "Unwritten text")
    #expect(model.dirty)
    #expect(model.error != nil)
    #expect(await model.save() == false)
  }

  @Test func sharedInitialLoadDoesNotDropAnIncomingTranscript() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let opening = Task { await model.load() }
    await model.create(text: "Saved while opening")
    await opening.value
    #expect(model.notes.map(\.text) == ["Saved while opening"])
    #expect(model.draft?.text == "Saved while opening")
  }

  @Test func explicitDiscardAfterFailureRestoresSavedTextWithoutWriting() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Previously saved")
    model.draft?.text = "Unsaved edit"
    let file = directory.appendingPathComponent("notes.json")
    try Data("corrupt".utf8).write(to: file)
    #expect(await model.save() == false)
    #expect(model.draft?.text == "Unsaved edit")
    model.discardChanges()
    #expect(model.draft?.text == "Previously saved")
    #expect(!model.dirty)
    #expect(model.error != nil)
    #expect(await model.save())
    #expect(try String(contentsOf: file, encoding: .utf8) == "corrupt")
  }

  @Test func closingSavesEditsBeforeHidingTheWindow() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Original")
    let controller = await makeNotesWorkspace(model: model, directory: directory)
    let window = try #require(controller.window)
    defer { window.close() }
    model.draft?.text = "Saved on close"
    #expect(!controller.windowShouldClose(window))
    for _ in 0..<50 {
      if !window.isVisible { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!window.isVisible)
    #expect(try await NoteStore(directory: directory).load().first?.text == "Saved on close")
  }

  @Test func deletionAndRestorationAreDurable() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Recover me")
    await model.setDeleted(true)
    #expect(model.visibleNotes.isEmpty)
    model.showingDeleted = true
    let deleted = try #require(model.visibleNotes.first)
    await model.select(deleted)
    await model.setDeleted(false)
    model.showingDeleted = false
    #expect(model.visibleNotes.count == 1)
    #expect(try await NoteStore(directory: directory).load().first?.deletedAt == nil)
  }

  @Test func corruptLoadDoesNotCreateOrOverwriteNotes() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("notes.json")
    try Data("corrupt".utf8).write(to: file)
    await model.create(text: "New")
    #expect(!model.loaded)
    #expect(model.draft == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "corrupt")
  }

  @Test func windowReusesNativeEditorAndPreventsClosingFailedSave() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Native note")
    let controller = await makeNotesWorkspace(model: model, directory: directory)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.present(coordinator: AppCoordinator(startAutomatically: false))
    #expect(controller.window === window)
    #expect(window.canBecomeKey)
    #expect(window.styleMask.contains(.resizable))
    window.contentView?.layoutSubtreeIfNeeded()
    for _ in 0..<30 {
      if textEditor(in: window.contentView) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = try #require(textEditor(in: window.contentView))
    if let directory = ProcessInfo.processInfo.environment["VANI_UI_SNAPSHOT_DIR"] {
      let content = try #require(window.contentView)
      let folder = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        // Allow native controls to finish their appearance transition before rendering.
        try await Task.sleep(for: .milliseconds(150))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("notes-\(appearance.rawValue).png"))
      }
    }
    // Appearance changes can replace the SwiftUI-backed native text view.
    let editor = try #require(textEditor(in: window.contentView))
    #expect(window.makeFirstResponder(editor))
    editor.selectAll(nil)
    editor.insertText(
      "Typed in the native editor", replacementRange: NSRange(location: NSNotFound, length: 0))
    for _ in 0..<30 {
      if model.draft?.text == "Typed in the native editor" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.draft?.text == "Typed in the native editor")
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("notes.json"))
    #expect(!controller.windowShouldClose(window))
    for _ in 0..<30 {
      if model.error != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(window.isVisible)
    #expect(model.draft?.text == "Typed in the native editor")
  }

  @Test func switchingCategorySavesDraftAndBlocksOnStorageFailure() async throws {
    let (directory, model) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.create(text: "Keep this thought")
    model.draft?.text = "Saved before switching"
    await model.showDeleted(true)
    #expect(model.showingDeleted)
    #expect(model.draft == nil)
    #expect(
      try await NoteStore(directory: directory).load().first?.text == "Saved before switching")
    await model.showDeleted(false)
    await model.select(model.notes.first)
    model.draft?.text = "Do not lose this edit"
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("notes.json"))
    await model.showDeleted(true)
    #expect(!model.showingDeleted)
    #expect(model.draft?.text == "Do not lose this edit")
    #expect(model.error != nil)
  }

  private func textEditor(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor { return editor }
    for child in view.subviews {
      if let editor = textEditor(in: child) { return editor }
    }
    return nil
  }
}

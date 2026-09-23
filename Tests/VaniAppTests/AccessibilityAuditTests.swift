import AppKit
import SwiftUI
import Testing
import VaniCore

@testable import Vani

private actor AuditRecognizer: SpeechRecognizing {
  func modelsAreInstalled() -> Bool { true }
  func prepare(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
  func transcribe(_ audio: CapturedAudio) throws -> SpeechResult {
    SpeechResult(
      text: "Fixture speech", confidence: 1, audioDuration: audio.duration, processingDuration: 0)
  }
}

private struct AuditSummarizer: MeetingSummarizing {
  func summarize(_ meeting: MeetingRecord) -> String { "Fixture summary" }
}

@MainActor
private final class AuditCapture: MeetingAudioRecording {
  var isCapturing = false
  func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) { isCapturing = true }
  func stop() { isCapturing = false }
}

/// Records announcements for the duration of a test, then restores the system announcer.
@MainActor
private final class AnnouncementRecorder {
  private(set) var messages: [String] = []
  private let original = VoiceOverAnnouncer.post

  init() {
    VoiceOverAnnouncer.post = { [weak self] in self?.messages.append($0) }
  }

  func restore() { VoiceOverAnnouncer.post = original }
}

extension NativeInteractionTests {
  /// Hosts every surface in a real window, walks its NSAccessibility tree as VoiceOver does,
  /// and checks names, images, disambiguation, state, headings and hidden content.
  /// Set VANI_A11Y_REPORT_DIR to write a readable outline of each tree.
  @Suite(.serialized) @MainActor
  struct AccessibilityAuditTests {
    // MARK: Menu

    @Test func menuStatesExposeNamedControlsAndHeadings() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      let coordinator = AppCoordinator(startAutomatically: false)
      try await audit(
        MenuContentView().environmentObject(coordinator), surface: "Menu - setup",
        AuditExpectations(headings: ["Set up Vani"]))

      try await audit(
        MenuLayout(status: "Ready", statusIcon: "checkmark.circle") {
          VStack(alignment: .leading, spacing: 12) {
            ReadyShortcutRow(
              shortcut: .function, globeKey: .showEmojiAndSymbols, handsFreeEnabled: true)
            ImprovedModelRow(progress: nil, install: {})
            LastDictationActions(binding: .controlCommand, canTeach: true)
          }
        }, surface: "Menu - ready",
        AuditExpectations(headings: ["Last dictation"]))
      try await audit(
        MenuLayout(status: "Ready", statusIcon: "checkmark.circle") {
          ImprovedModelRow(progress: 0.42, install: {})
        }, surface: "Menu - model download",
        AuditExpectations(values: ["Downloading speech model": "0.42"]))
      try await audit(
        MenuLayout(status: "Listening", statusIcon: "record.circle") {
          DictationProgressView(phase: .listening, handsFree: false, shortcut: .function)
        }, surface: "Menu - listening",
        AuditExpectations(headings: ["Listening"]))
      try await audit(
        MenuLayout(status: "Listening", statusIcon: "record.circle") {
          DictationProgressView(phase: .listening, handsFree: true, shortcut: .rightOption)
        }, surface: "Menu - hands-free",
        AuditExpectations(headings: ["Listening"]))
      try await audit(
        MenuLayout(status: "Transcribing…", statusIcon: "ellipsis.circle") {
          DictationProgressView(phase: .transcribing, handsFree: false, shortcut: .function)
        }, surface: "Menu - transcribing",
        AuditExpectations(headings: ["Transcribing…"]))
      try await audit(
        MenuLayout(
          status: "Needs attention", statusIcon: "exclamationmark.circle",
          error: "Settings could not be saved."
        ) {
          RecoveryContent(
            snapshot: SessionSnapshot(
              phase: .recoverableError, failure: .clipboardChanged,
              hasRecoverableTranscript: true, recoverableTranscript: "Preserved words"),
            primaryLabel: "Retry", primaryIcon: "arrow.clockwise")
        }, surface: "Menu - error",
        AuditExpectations(headings: [VaniFailure.clipboardChanged.title]))
      try await audit(
        MenuLayout(status: "Shortcut inactive", statusIcon: "exclamationmark.circle") {
          ShortcutInactiveView(quit: {}, canRelaunch: true)
        }, surface: "Menu - shortcut inactive",
        AuditExpectations(headings: ["Shortcut not active"]))
      try await audit(
        MenuLayout(status: "Preparing speech model", statusIcon: "circle.dotted") {
          PreparationView(progress: 0.3)
        }, surface: "Menu - preparing",
        AuditExpectations(
          headings: ["Preparing local speech model"],
          values: ["Speech model download": "0.3"]))
      try await audit(
        MenuLayout(status: "Meeting in progress", statusIcon: "circle.dotted") {
          MeetingInProgressView(open: {})
        }, surface: "Menu - meeting",
        AuditExpectations(headings: ["Meeting in progress"]))
    }

    // MARK: Workspace: Meetings

    @Test func meetingsExposeSelectionTabsTranscriptStateAndAnnouncements() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      let announcements = AnnouncementRecorder()
      defer { announcements.restore() }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let hiddenSections = ["Search notes", "New note", "Settings section"]
      do {
        let empty = makeMeetingModel(directory.appendingPathComponent("Empty"))
        await empty.load()
        let (controller, _) = try await presentWorkspace(meetings: empty, directory)
        let window = try #require(controller.window)
        defer { window.close() }
        try await audit(
          window, surface: "Meetings - empty",
          AuditExpectations(
            headings: ["Meetings"], absent: hiddenSections,
            selected: ["Meetings", "All Meetings"]))
      }

      let store = MeetingStore(directory: directory.appendingPathComponent("Meetings"))
      var meeting = MeetingRecord(title: "Design review")
      meeting.endedAt = Date()
      meeting.notes = "Private meeting notes"
      meeting.transcript = [
        .init(id: UUID(), source: .microphone, offset: 0, duration: 20, text: "Let us begin."),
        .init(id: UUID(), source: .system, offset: 20, duration: 20, text: "Agreed, Friday."),
        .init(
          id: UUID(), source: .microphone, offset: 21, duration: 19, text: "Agreed, Friday.",
          echoOfSystemAudio: true),
        .init(id: UUID(), source: .system, offset: 40, duration: 20, text: "", failed: true),
      ]
      meeting.summary = "Summary\nShip on Friday."
      try await store.save(meeting)
      var other = MeetingRecord(title: "Weekly sync")
      other.endedAt = Date()
      try await store.save(other)
      let model = makeMeetingModel(directory.appendingPathComponent("Meetings"))
      await model.load()
      let (controller, _) = try await presentWorkspace(meetings: model, directory)
      let window = try #require(controller.window)
      defer { window.close() }
      await model.select(try #require(model.meetings.first { $0.id == meeting.id }))
      let tabs = try await segmentedControl(in: window, first: "My notes")
      for (index, name) in ["My notes", "Transcript", "Summary"].enumerated() {
        if name == "Transcript" { model.showingEchoes = true }
        tabs.selectedSegment = index
        tabs.sendAction(tabs.action, to: tabs.target)
        try await audit(
          window, surface: "Meetings - \(name.lowercased())",
          AuditExpectations(
            headings: ["Meetings"], absent: hiddenSections,
            selected: ["Meetings", "All Meetings", "Design review", name],
            unselected: ["Weekly sync"]))
        if name == "Transcript" {
          let failed = AccessibilityAudit.tree(of: window).flattened.first {
            AccessibilityAudit.spoken($0)?.contains("Couldn’t transcribe") == true
          }
          #expect(failed?.help?.contains("Recover transcript") == true)
        }
      }

      await model.setDeleted(true)
      await model.showDeleted(true)
      await model.select(try #require(model.meetings.first { $0.id == meeting.id }))
      try await audit(
        window, surface: "Meetings - recently deleted",
        AuditExpectations(
          absent: hiddenSections, selected: ["Recently Deleted Meetings", "Design review"],
          named: ["Restore meeting"]))
      await model.setDeleted(false)
      await model.showDeleted(false)

      await model.start()
      #expect(model.phase == .recording)
      try await audit(
        window, surface: "Meetings - recording",
        AuditExpectations(
          headings: ["Meeting in progress"], absent: hiddenSections,
          named: ["Stop meeting", "Meeting recording"]))
      await model.stop(summarize: false)
      try await Task.sleep(for: .milliseconds(200))
      #expect(announcements.messages.contains("Meeting recording started"))
      #expect(announcements.messages.contains("Meeting recording stopped"))
      #expect(!announcements.messages.contains { $0.contains("Private meeting notes") })
    }

    // MARK: Workspace: Notes

    @Test func notesExposeLibraryEditorDeletedAndErrorStates() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      let announcements = AnnouncementRecorder()
      defer { announcements.restore() }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let notesDirectory = directory.appendingPathComponent("Notes")
      let notes = NotesModel(store: NoteStore(directory: notesDirectory))
      await notes.create(text: "Groceries\n\nPrivate note text")
      await notes.create(text: "Ideas\n\nAnother private line")
      let meetings = MeetingModel(
        store: MeetingStore(directory: directory.appendingPathComponent("Meetings")),
        recognizer: NotesUITestRecognizer(), reserveSpeech: { false }, releaseSpeech: {})
      let (controller, workspace) = try await presentWorkspace(
        meetings: meetings, directory, notes: notes, section: .notes)
      let window = try #require(controller.window)
      defer { window.close() }
      let hiddenSections = ["Search meetings", "New meeting", "Settings section"]
      try await audit(
        window, surface: "Notes - editor",
        AuditExpectations(
          headings: ["Notes"], absent: hiddenSections,
          selected: ["Notes", "All Notes", "Ideas"], unselected: ["Groceries"],
          named: ["Note title", "Note text", "Search notes"]))

      await notes.setDeleted(true)
      await notes.showDeleted(true)
      await notes.select(notes.visibleNotes.first)
      try await audit(
        window, surface: "Notes - recently deleted",
        AuditExpectations(
          absent: hiddenSections, selected: ["Recently Deleted Notes", "Ideas"],
          named: ["Restore note"]))
      await notes.showDeleted(false)
      await notes.select(nil)
      try await audit(
        window, surface: "Notes - nothing selected",
        AuditExpectations(headings: ["Select or create a note"], absent: hiddenSections))

      await notes.select(notes.visibleNotes.first)
      notes.draft?.text = "An unsaved private edit"
      try Data("corrupt".utf8).write(to: notesDirectory.appendingPathComponent("notes.json"))
      #expect(!(await notes.save()))
      try await audit(
        window, surface: "Notes - error",
        AuditExpectations(absent: hiddenSections, named: ["Discard Changes…"]))
      #expect(announcements.messages.contains { $0.hasPrefix("Notes: ") })
      #expect(!announcements.messages.contains { $0.localizedCaseInsensitiveContains("private") })
      notes.discardChanges()

      #expect(await workspace.select(.settings))
      try await audit(
        window, surface: "Workspace - settings",
        AuditExpectations(
          headings: ["Settings"],
          absent: ["Search notes", "New note", "Search meetings", "New meeting", "Note text"],
          selected: ["Settings", "General"]))
    }

    // MARK: Settings

    @Test func settingsPanesExposeNamedControlsAndDisambiguatedRows() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      let coordinator = AppCoordinator(startAutomatically: false)
      // Assigned directly: the audit never persists settings.
      coordinator.settings.dictionary = [
        DictionaryEntry(spoken: "vani", replacement: "Vani"),
        DictionaryEntry(spoken: "mrinoy", replacement: "Mrinoy"),
      ]
      coordinator.settings.snippets = [
        SnippetEntry(trigger: "my address", expansion: "1 Infinite Loop"),
        SnippetEntry(trigger: "sign off", expansion: "Best,\nM"),
      ]
      try await audit(
        SettingsView(section: .general).environmentObject(coordinator),
        surface: "Settings - general",
        AuditExpectations(
          headings: ["Settings"], selected: ["General"],
          named: ["Double-tap for hands-free", "Launch Vani at login"]),
        size: NSSize(width: 640, height: 720))
      try await audit(
        SettingsView(section: .vocabulary).environmentObject(coordinator),
        surface: "Settings - vocabulary",
        AuditExpectations(
          selected: ["Vocabulary", "Dictionary"],
          named: [
            "Delete dictionary entry vani", "Delete dictionary entry mrinoy", "Spoken phrase",
            "Replacement", "Add dictionary correction",
          ]),
        size: NSSize(width: 640, height: 560))
      try await audit(
        SettingsView(section: .snippets).environmentObject(coordinator),
        surface: "Settings - snippets",
        AuditExpectations(
          selected: ["Snippets"],
          named: [
            "Edit snippet my address", "Delete snippet my address", "Edit snippet sign off",
            "Delete snippet sign off", "Voice trigger", "Expanded snippet text", "Add snippet",
          ]),
        size: NSSize(width: 640, height: 560))
      try await audit(
        SettingsView(section: .history).environmentObject(coordinator),
        surface: "Settings - history empty", AuditExpectations(selected: ["History"]),
        size: NSSize(width: 640, height: 480))

      try await audit(
        LearningSettingsContent(
          corrections: [
            LearnedCorrection(spoken: "vanny", replacement: "Vani", confirmationCount: 3),
            LearnedCorrection(
              spoken: "go getter", replacement: "Go-Getter",
              applicationBundleIdentifier: "com.apple.mail"),
          ],
          enabled: .constant(true), modelInstalled: false, modelProgress: 0.5,
          download: {}, remove: { _ in }, removeOffsets: { _ in }, reset: {}),
        surface: "Settings - learning",
        AuditExpectations(
          named: [
            "Delete learned correction vanny", "Delete learned correction go getter",
            "Learn from corrections", "Reset Learning…",
          ],
          values: ["Downloading acoustic vocabulary model": "0.5"]),
        size: NSSize(width: 640, height: 520))
      try await audit(
        HistorySettingsContent(
          entries: [
            TranscriptHistoryEntry(text: "First dictation"),
            TranscriptHistoryEntry(text: "Second dictation"),
          ], historyEnabled: true, canClear: true, clear: {}),
        surface: "Settings - history", AuditExpectations(named: ["Clear History…"]),
        size: NSSize(width: 640, height: 420))
      try await audit(
        DiagnosticsSettingsContent(
          events: [
            DiagnosticEvent(
              category: .transcription, code: "transcribed", durationMilliseconds: 180),
            DiagnosticEvent(category: .insertion, code: "inserted"),
          ], refresh: {}, clear: {}),
        surface: "Settings - diagnostics",
        AuditExpectations(named: ["Refresh diagnostics", "Clear Diagnostics…"]),
        size: NSSize(width: 640, height: 420))
    }

    // MARK: Teach and overlay

    @Test func teachWindowNamesItsEditorAndAnnouncesAFailedSave() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      let announcements = AnnouncementRecorder()
      defer { announcements.restore() }
      let controller = TeachWindowController(activateApplication: {})
      controller.present(candidate: TeachQAWindowFixture.candidate, save: { _ in false })
      defer { controller.dismiss() }
      let window = try #require(controller.window)
      try await audit(
        window, surface: "Teach",
        AuditExpectations(
          headings: ["Correct dictation"],
          named: ["Corrected transcript", "Cancel", "Save Learning"]))
      await waitUntil { window.firstResponder is NSTextView }
      let editor = try #require(window.firstResponder as? NSTextView)
      editor.selectAll(nil)
      editor.insertText("Vani learns locally", replacementRange: editor.selectedRange())
      try await Task.sleep(for: .milliseconds(100))
      #expect(window.performKeyEquivalent(with: try key("s", code: 1, window: window)))
      await waitUntil { announcements.messages.contains("Correction not saved") }
      try await audit(
        window, surface: "Teach - save failed",
        AuditExpectations(
          named: ["The correction wasn’t saved. Your edit is still here; try again."]))
      #expect(announcements.messages == ["Correction not saved"])
    }

    @Test func overlayPanelExposesOneLabelledStatusAndAnnouncesStops() async throws {
      AccessibilityAudit.enableAccessibilityTree()
      var announced: [String] = []
      let overlay = OverlayController(announce: { announced.append($0) })
      defer { overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .ready) }
      overlay.update(snapshot: SessionSnapshot(phase: .listening), previousPhase: .ready)
      let panel = try #require(overlay.contentView.window)
      try await audit(
        panel, surface: "Overlay - listening", AuditExpectations(named: ["Listening"]))
      overlay.handsFree = true
      try await audit(
        panel, surface: "Overlay - hands-free", AuditExpectations(named: ["Hands-free"]))
      overlay.handsFree = false
      overlay.update(snapshot: SessionSnapshot(phase: .ready), previousPhase: .listening)
      overlay.update(
        snapshot: SessionSnapshot(phase: .recoverableError, failure: .clipboardChanged),
        previousPhase: .transcribing)
      try await audit(
        panel, surface: "Overlay - failure",
        AuditExpectations(named: [VaniFailure.clipboardChanged.title]))
      #expect(
        announced == [
          "Listening", "Hands-free recording locked", "Listening", "Recording stopped",
          VaniFailure.clipboardChanged.title,
        ])
    }

    // MARK: Keyboard

    @Test func workspaceSectionsSearchAndNewMeetingWorkFromTheKeyboard() async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let meetings = makeMeetingModel(directory.appendingPathComponent("Meetings"))
      await meetings.load()
      let (controller, workspace) = try await presentWorkspace(meetings: meetings, directory)
      let window = try #require(controller.window)
      defer { window.close() }
      let content = try #require(window.contentView)
      content.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))

      for (character, code, section) in [
        ("2", UInt16(19), WorkspaceModel.Section.notes), ("3", 20, .settings), ("1", 18, .meetings),
      ] {
        #expect(window.performKeyEquivalent(with: try key(character, code: code, window: window)))
        await waitUntil { workspace.selection == section && !workspace.transitioning }
        #expect(workspace.selection == section)
        // Sidebar buttons are disabled during a transition; let SwiftUI re-enable them.
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
      }

      func searchField() -> NSTextField? {
        descendants(content, NSTextField.self).first {
          $0.placeholderString == "Search meetings" && $0.isEnabled
        }
      }
      await waitUntil { searchField() != nil }
      content.layoutSubtreeIfNeeded()
      #expect(window.performKeyEquivalent(with: try key("f", code: 3, window: window)))
      let field = try #require(searchField())
      await waitUntil { field.currentEditor() != nil }
      #expect(field.currentEditor() === window.firstResponder)
      window.makeFirstResponder(nil)

      // Command-N asks for recording consent; it never starts capture by itself.
      #expect(window.performKeyEquivalent(with: try key("n", code: 45, window: window)))
      await waitUntil { window.attachedSheet != nil }
      let sheet = try #require(window.attachedSheet)
      #expect(meetings.phase == .idle)
      window.endSheet(sheet)
    }

    // MARK: Contrast snapshots

    /// Renders selection in the high-contrast appearances (Increase Contrast), set on the
    /// window only, when VANI_UI_SNAPSHOT_DIR is set.
    @Test func captureHighContrastSelectionWhenRequested() async throws {
      guard let path = ProcessInfo.processInfo.environment["VANI_UI_SNAPSHOT_DIR"] else { return }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = MeetingStore(directory: directory.appendingPathComponent("Meetings"))
      for title in ["Weekly sync", "Design review"] {
        var meeting = MeetingRecord(title: title)
        meeting.endedAt = Date()
        meeting.notes = "Keep the first experience focused."
        try await store.save(meeting)
      }
      let meetings = makeMeetingModel(directory.appendingPathComponent("Meetings"))
      await meetings.load()
      await meetings.select(try #require(meetings.meetings.first))
      let workspace = WorkspaceModel(
        notes: NotesModel(store: NoteStore(directory: directory.appendingPathComponent("Notes"))),
        meetings: meetings)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: WorkspaceView(model: workspace)
          .environmentObject(AppCoordinator(startAutomatically: false)))
      window.setContentSize(NSSize(width: 1060, height: 720))
      window.orderFront(nil)
      defer { window.close() }
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for appearance in [
        NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
      ] {
        window.appearance = NSAppearance(named: appearance)
        try await Task.sleep(for: .milliseconds(200))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: folder.appendingPathComponent("meetings-contrast-\(appearance.rawValue).png"))
      }
    }

    // MARK: Helpers

    private func makeMeetingModel(_ directory: URL) -> MeetingModel {
      MeetingModel(
        store: MeetingStore(directory: directory), recognizer: AuditRecognizer(),
        summarizer: AuditSummarizer(), makeCapture: { AuditCapture() },
        reserveSpeech: { true }, releaseSpeech: {}, captureSupported: true)
    }

    private func presentWorkspace(
      meetings: MeetingModel, _ directory: URL, notes: NotesModel? = nil,
      section: WorkspaceModel.Section = .meetings
    ) async throws -> (WorkspaceWindowController, WorkspaceModel) {
      let workspace = WorkspaceModel(
        notes: notes
          ?? NotesModel(store: NoteStore(directory: directory.appendingPathComponent("Notes"))),
        meetings: meetings)
      #expect(await workspace.select(section))
      let controller = WorkspaceWindowController(model: workspace)
      controller.present(coordinator: AppCoordinator(startAutomatically: false))
      return (controller, workspace)
    }

    private func audit<Content: View>(
      _ view: Content, surface: String, _ expectations: AuditExpectations,
      size: NSSize? = nil
    ) async throws {
      let hosting = NSHostingController(rootView: view)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = surface
      window.contentViewController = hosting
      window.setContentSize(size ?? hosting.view.fittingSize)
      window.orderFront(nil)
      defer { window.close() }
      try await audit(window, surface: surface, expectations)
    }

    private func audit(
      _ window: NSWindow, surface: String, _ expectations: AuditExpectations
    ) async throws {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(350))
      let tree = AccessibilityAudit.tree(of: window)
      try AccessibilityAudit.writeReport(tree, surface: surface)
      for finding in AccessibilityAudit.findings(in: tree, expectations) {
        Issue.record("\(surface): \(finding)")
      }
    }

    private func segmentedControl(in window: NSWindow, first label: String) async throws
      -> NSSegmentedControl
    {
      let content = try #require(window.contentView)
      func find() -> NSSegmentedControl? {
        descendants(content, NSSegmentedControl.self).first {
          $0.segmentCount > 0 && $0.label(forSegment: 0) == label
        }
      }
      await waitUntil { find() != nil }
      return try #require(find())
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
      (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func key(_ character: String, code: UInt16, window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    private func waitUntil(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(3)
      while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
  }
}

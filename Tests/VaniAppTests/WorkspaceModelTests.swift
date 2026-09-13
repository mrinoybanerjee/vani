import Foundation
import Testing
import VaniCore

@testable import Vani

private actor WorkspaceTestRecognizer: SpeechRecognizing {
  func modelsAreInstalled() -> Bool { true }
  func prepare(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
  func transcribe(_ audio: CapturedAudio) -> SpeechResult {
    SpeechResult(
      text: "Fixture transcript", confidence: 1, audioDuration: audio.duration,
      processingDuration: 0)
  }
}

private struct WorkspaceTestSummarizer: MeetingSummarizing {
  func summarize(_ meeting: MeetingRecord) -> String { "Fixture summary" }
}

@MainActor
private final class WorkspaceTestCapture: MeetingAudioRecording {
  private(set) var isCapturing = false
  private(set) var starts = 0
  private(set) var stops = 0

  func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) {
    starts += 1
    isCapturing = true
  }

  func stop() {
    stops += 1
    isCapturing = false
  }
}

@Suite(.serialized) @MainActor
struct WorkspaceModelTests {
  private func fixture() -> (URL, WorkspaceModel, WorkspaceTestCapture) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let capture = WorkspaceTestCapture()
    let meetings = MeetingModel(
      store: MeetingStore(directory: directory.appendingPathComponent("Meetings")),
      recognizer: WorkspaceTestRecognizer(), summarizer: WorkspaceTestSummarizer(),
      makeCapture: { capture }, reserveSpeech: { true }, releaseSpeech: {})
    let notes = NotesModel(store: NoteStore(directory: directory.appendingPathComponent("Notes")))
    return (directory, WorkspaceModel(notes: notes, meetings: meetings), capture)
  }

  @Test func leavingNotesSavesEditsAndReturningKeepsTheSelectedDraft() async throws {
    let (directory, workspace, _) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await workspace.select(.notes))
    await workspace.notes.create(text: "Original note")
    let noteID = try #require(workspace.notes.draft?.id)
    workspace.notes.draft?.text = "Edited before opening Settings"

    #expect(await workspace.select(.settings))
    #expect(workspace.selection == .settings && !workspace.transitioning)
    #expect(!workspace.notes.dirty)
    let saved = try await NoteStore(directory: directory.appendingPathComponent("Notes")).load()
    #expect(saved.first?.text == "Edited before opening Settings")
    #expect(await workspace.select(.notes))
    #expect(workspace.notes.draft?.id == noteID)
    #expect(workspace.notes.draft?.text == saved.first?.text)
  }

  @Test func leavingMeetingsSavesEditsBeforeOpeningNotes() async throws {
    let (directory, workspace, _) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await workspace.select(.meetings))
    workspace.meetings.draft = MeetingRecord(title: "Planning")
    #expect(await workspace.meetings.save())
    workspace.meetings.draft?.notes = "Decision added immediately before switching"

    #expect(await workspace.select(.notes))
    #expect(workspace.selection == .notes && workspace.notes.loaded)
    #expect(!workspace.meetings.dirty)
    let saved = try await MeetingStore(directory: directory.appendingPathComponent("Meetings"))
      .load()
    #expect(saved.first?.notes == "Decision added immediately before switching")
  }

  @Test(arguments: [WorkspaceModel.Section.notes, .meetings])
  func failedSaveBlocksNavigationAndPreservesTheOutgoingDraft(
    section: WorkspaceModel.Section
  ) async throws {
    let (directory, workspace, _) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await workspace.select(section))
    let file = try await prepareFailedSave(
      section: section, workspace: workspace, directory: directory)

    #expect(await workspace.select(.settings) == false)
    #expect(workspace.selection == section && !workspace.transitioning)
    expectUnsavedDraft(section: section, workspace: workspace)
    #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
  }

  @Test(arguments: [WorkspaceModel.Section.notes, .meetings])
  func failedCloseRevealsTheHiddenDraftInsteadOfDiscardingIt(
    section: WorkspaceModel.Section
  ) async throws {
    let (directory, workspace, _) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await workspace.select(.settings))
    let file = try await prepareFailedSave(
      section: section, workspace: workspace, directory: directory)

    #expect(await workspace.prepareToClose() == false)
    #expect(workspace.selection == section && !workspace.transitioning)
    expectUnsavedDraft(section: section, workspace: workspace)
    #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
  }

  @Test func navigationAndWindowCloseKeepRecordingButQuitStopsItOnce() async throws {
    let (directory, workspace, capture) = fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await workspace.meetings.start()
    #expect(workspace.meetings.phase == .recording && capture.starts == 1)
    let meetingID = try #require(workspace.meetings.draft?.id)
    workspace.meetings.draft?.notes = "Notes made during the meeting"

    #expect(await workspace.select(.notes))
    await workspace.notes.create(text: "A separate note")
    #expect(await workspace.select(.settings))
    #expect(await workspace.prepareToClose())
    #expect(capture.isCapturing && capture.stops == 0)
    #expect(workspace.meetings.phase == .recording)
    #expect(workspace.meetings.draft?.id == meetingID)
    #expect(workspace.meetings.draft?.endedAt == nil)
    let store = MeetingStore(directory: directory.appendingPathComponent("Meetings"))
    #expect(try await store.load().first?.notes == "Notes made during the meeting")

    #expect(await workspace.prepareToClose(quitting: true))
    #expect(!capture.isCapturing && capture.stops == 1)
    #expect(workspace.meetings.phase == .idle)
    #expect(try await store.load().first?.endedAt != nil)
    #expect(await workspace.prepareToClose(quitting: true))
    #expect(capture.stops == 1)
  }

  private func prepareFailedSave(
    section: WorkspaceModel.Section, workspace: WorkspaceModel, directory: URL
  ) async throws -> URL {
    let file: URL
    if section == .notes {
      await workspace.notes.create(text: "Saved note")
      workspace.notes.draft?.text = "Unsaved draft must survive"
      file = directory.appendingPathComponent("Notes/notes.json")
    } else {
      await workspace.meetings.load()
      workspace.meetings.draft = MeetingRecord(title: "Saved meeting")
      #expect(await workspace.meetings.save())
      let id = try #require(workspace.meetings.draft?.id)
      workspace.meetings.draft?.notes = "Unsaved draft must survive"
      file = directory.appendingPathComponent("Meetings/\(id.uuidString)/meeting.json")
    }
    try Data("corrupt".utf8).write(to: file)
    return file
  }

  private func expectUnsavedDraft(section: WorkspaceModel.Section, workspace: WorkspaceModel) {
    if section == .notes {
      #expect(workspace.notes.draft?.text == "Unsaved draft must survive")
      #expect(workspace.notes.dirty && workspace.notes.error != nil)
    } else {
      #expect(workspace.meetings.draft?.notes == "Unsaved draft must survive")
      #expect(workspace.meetings.dirty && workspace.meetings.error != nil)
    }
  }
}

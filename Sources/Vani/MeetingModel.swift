import Foundation
import VaniCore

@MainActor
final class MeetingModel: ObservableObject {
  enum Phase: Equatable {
    case idle, preparing, recording, stopping, finishing, transcribing, summarizing
  }
  @Published private(set) var meetings: [MeetingRecord] = []
  @Published var draft: MeetingRecord?
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var error: String?
  @Published private(set) var loaded = false
  @Published private(set) var saving = false
  @Published private(set) var transcriptionFailed = false
  @Published var search = ""
  private let store: MeetingStore
  private let recognizer: any SpeechRecognizing
  private let summarizer: any MeetingSummarizing
  private let makeCapture: () throws -> any MeetingAudioRecording
  private let reserveSpeech: () -> Bool
  private let releaseSpeech: () -> Void
  private var recorder: (any MeetingAudioRecording)?
  private var drainTask: Task<Void, Never>?
  private var lastSaved: MeetingRecord?
  private var loadTask: Task<Void, Never>?
  private var captureStartFailure: String?
  private var activeCaptureID: UUID?
  private var summaryTask: Task<String, Error>?

  init(
    store: MeetingStore = MeetingStore(), recognizer: any SpeechRecognizing,
    summarizer: any MeetingSummarizing = LocalMeetingSummarizer(),
    makeCapture: @escaping () throws -> any MeetingAudioRecording = {
      if #available(macOS 15.0, *) { return MeetingAudioCapture() }
      throw MeetingError.capture(
        "Meeting capture requires macOS 15 or later. Dictation and quick notes remain available.")
    }, reserveSpeech: @escaping () -> Bool, releaseSpeech: @escaping () -> Void
  ) {
    self.store = store
    self.recognizer = recognizer
    self.summarizer = summarizer
    self.makeCapture = makeCapture
    self.reserveSpeech = reserveSpeech
    self.releaseSpeech = releaseSpeech
  }

  var busy: Bool { phase != .idle }
  var dirty: Bool { draft != lastSaved }
  var visibleMeetings: [MeetingRecord] {
    meetings.filter {
      $0.deletedAt == nil
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || $0.notes.localizedCaseInsensitiveContains(search)
          || $0.transcript.contains { $0.text.localizedCaseInsensitiveContains(search) })
    }
  }

  func load() async {
    guard !loaded else { return }
    if let loadTask {
      await loadTask.value
      return
    }
    let task = Task {
      defer { loadTask = nil }
      do {
        meetings = try await store.load()
        loaded = true
        error = nil
      } catch { self.error = error.localizedDescription }
    }
    loadTask = task
    await task.value
  }

  @discardableResult
  func save() async -> Bool {
    guard !saving else { return false }
    guard let draft, dirty else { return true }
    saving = true
    defer { saving = false }
    do {
      try await store.save(draft)
      lastSaved = draft
      if let index = meetings.firstIndex(where: { $0.id == draft.id }) {
        meetings[index] = draft
      } else {
        meetings.insert(draft, at: 0)
      }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func select(_ meeting: MeetingRecord) async {
    guard !busy, await saveBeforeTransition(), !busy else { return }
    let saved = meetings.first { $0.id == meeting.id }
    draft = saved
    lastSaved = saved
    error = nil
    transcriptionFailed = false
  }

  func start() async {
    guard phase == .idle, await saveBeforeTransition(), phase == .idle else { return }
    guard reserveSpeech() else {
      error = "Finish your current dictation before starting a meeting."
      return
    }
    // Reservation is synchronous and precedes microphone/model setup.
    phase = .preparing
    let captureID = UUID()
    activeCaptureID = captureID
    captureStartFailure = nil
    error = nil
    transcriptionFailed = false
    do {
      if !loaded { await load() }
      guard loaded else {
        throw MeetingError.storage(
          "Meeting storage is unavailable. Your existing meetings have been preserved.")
      }
      let capture = try makeCapture()
      guard await recognizer.modelsAreInstalled() else {
        throw MeetingError.capture("Download the local speech model from the Vani menu first.")
      }
      try await recognizer.prepare { _ in }
      draft = MeetingRecord(
        title: Date().formatted(.dateTime.month(.abbreviated).day()) + " meeting")
      lastSaved = nil
      guard await save(), let draft else {
        throw MeetingError.storage("The meeting could not be created. Check available disk space.")
      }
      let directory = try await store.audioDirectory(for: draft.id)
      try await capture.start(
        directory: directory,
        onChunk: { [weak self] in
          Task { @MainActor in
            guard let self, self.activeCaptureID == captureID else { return }
            self.requestDrain()
          }
        },
        onFailure: { [weak self] message in
          Task { @MainActor in
            guard let self, self.activeCaptureID == captureID else { return }
            self.error = message
            if self.phase == .preparing { self.captureStartFailure = message }
            if self.phase == .recording { await self.stop(summarize: false) }
          }
        })
      recorder = capture
      phase = .recording
      if captureStartFailure != nil { await stop(summarize: false) }
    } catch {
      self.error = error.localizedDescription
      activeCaptureID = nil
      phase = .idle
      releaseSpeech()
    }
  }

  func stop(summarize: Bool = true) async {
    guard phase == .recording || phase == .finishing, let recorder else { return }
    phase = .stopping
    do { try await recorder.stop() } catch {
      self.error = "Could not finish capture: \(error.localizedDescription). Try Stop again."
      phase = recorder.isCapturing ? .recording : .finishing
      return
    }
    self.recorder = nil
    activeCaptureID = nil
    draft?.endedAt = Date()
    phase = .transcribing
    await drainTask?.value
    if !transcriptionFailed { await drain() }
    while saving { try? await Task.sleep(for: .milliseconds(10)) }
    let saved = await save()
    phase = .idle
    releaseSpeech()
    if summarize && saved && !transcriptionFailed { await generateSummary() }
  }

  func interrupt(_ message: String) async {
    guard phase == .preparing || phase == .recording || phase == .finishing else { return }
    error = message
    if phase == .preparing { captureStartFailure = message } else { await stop(summarize: false) }
  }

  func recoverTranscript() async {
    guard phase == .idle, draft != nil, reserveSpeech() else { return }
    phase = .transcribing
    error = nil
    transcriptionFailed = false
    defer {
      phase = .idle
      releaseSpeech()
    }
    do { try await recognizer.prepare { _ in } } catch {
      transcriptionFailed = true
      self.error = error.localizedDescription
      return
    }
    await drain()
    if draft?.endedAt == nil { draft?.endedAt = Date() }
    _ = await save()
  }

  func generateSummary() async {
    guard phase == .idle, !transcriptionFailed, let original = draft else { return }
    phase = .summarizing
    error = nil
    defer {
      phase = .idle
      summaryTask = nil
    }
    do {
      guard try await store.pendingAudioFiles(for: original).isEmpty else {
        throw MeetingError.summary("Finish recovering the transcript before generating a summary.")
      }
      let task = Task { try await summarizer.summarize(original) }
      summaryTask = task
      let text = try await task.value
      guard !task.isCancelled else { throw CancellationError() }
      guard draft?.id == original.id, draft?.transcript == original.transcript,
        draft?.notes == original.notes
      else {
        throw MeetingError.summary(
          "The meeting changed while summarizing. Generate again to include your latest edits.")
      }
      draft?.summary = text
      _ = await save()
    } catch is CancellationError {
      self.error = "Summary cancelled. Your transcript and previous summary are preserved."
    } catch { self.error = error.localizedDescription }
  }

  func cancelSummary() { summaryTask?.cancel() }

  func prepareToClose() async -> Bool {
    // Closing a window during a meeting only hides it; capture remains explicit in the menu.
    while saving { try? await Task.sleep(for: .milliseconds(10)) }
    return await saveBeforeTransition()
  }

  private func saveBeforeTransition() async -> Bool {
    guard await save() else { return false }
    return !dirty
  }

  func prepareToQuit() async -> Bool {
    guard phase != .preparing && phase != .stopping && phase != .summarizing else {
      error = "Wait for the current meeting operation to finish before quitting."
      return false
    }
    if phase == .recording || phase == .finishing { await stop(summarize: false) }
    guard phase == .idle else { return false }
    return await prepareToClose()
  }

  func clearAudio() async {
    guard !busy, !saving, await saveBeforeTransition(), let draft else { return }
    do {
      guard let durable = try await store.load().first(where: { $0.id == draft.id }),
        try await store.pendingAudioFiles(for: durable).isEmpty
      else {
        throw MeetingError.storage("Recover all remaining transcript audio before removing it.")
      }
      try await store.deleteAudio(for: draft.id)
    } catch { self.error = error.localizedDescription }
  }

  private func requestDrain() {
    guard drainTask == nil, !transcriptionFailed, phase == .recording || phase == .preparing else {
      return
    }
    drainTask = Task { [weak self] in
      guard let self else { return }
      await drain()
      drainTask = nil
    }
  }

  private func drain() async {
    do {
      while let current = draft {
        let files = try await store.pendingAudioFiles(for: current)
        guard let file = files.first else { return }
        let chunk = try await store.readAudio(file, meetingID: current.id)
        let audio = try chunk.audio()
        let text: String
        if audio.rootMeanSquare < 0.0015 || audio.duration < 0.18 {
          text = ""
        } else {
          text = try await recognizer.transcribe(audio).text
        }
        guard draft?.id == current.id else { return }
        while saving { try? await Task.sleep(for: .milliseconds(10)) }
        let segment = MeetingTranscriptSegment(
          id: chunk.id, source: chunk.source,
          offset: chunk.offset, duration: audio.duration, text: text)
        if draft?.transcript.contains(where: { $0.id == chunk.id }) == false {
          draft?.transcript.append(segment)
        }
        guard await save() else {
          throw MeetingError.storage(
            "The transcript could not be saved. Captured audio is preserved for recovery.")
        }
      }
    } catch {
      transcriptionFailed = true
      self.error =
        "Live transcription paused: \(error.localizedDescription). Captured audio remains on this Mac; use Recover transcript after stopping."
    }
  }
}

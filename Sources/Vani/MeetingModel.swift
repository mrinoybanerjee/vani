import Foundation
import VaniCore

@MainActor
final class MeetingModel: ObservableObject {
  enum Phase: Equatable {
    /// `summarizing` is not entered: summaries run in the background (see `summarizingID`) so
    /// the library stays usable. The case remains for exhaustive switches in shared views.
    case idle, preparing, recording, stopping, finishing, transcribing, summarizing
  }
  /// Loudest 30 ms frame below this RMS is treated as silence. Silent Mac audio is 0 and a quiet
  /// room microphone stays near 0.001–0.003; even soft speech frames exceed 0.01.
  static let silenceThreshold: Float = 0.004
  static let minimumSpeechDuration: TimeInterval = 0.18
  /// A chunk that fails transcription this many times is saved as a visible failure placeholder.
  static let maximumTranscriptionAttempts = 3

  @Published private(set) var meetings: [MeetingRecord] = []
  @Published var draft: MeetingRecord? {
    didSet {
      if oldValue?.id != draft?.id || oldValue?.transcript != draft?.transcript {
        refreshTranscript()
      }
    }
  }
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var error: String?
  @Published private(set) var loaded = false
  @Published private(set) var saving = false
  @Published private(set) var transcriptionFailed = false
  @Published var search = ""
  @Published private(set) var showingDeleted = false
  /// Echo copies are hidden by default; this reveals them for review.
  @Published var showingEchoes = false { didSet { refreshTranscript() } }
  /// The transcript as displayed: time-ordered, without silence and hidden echo copies.
  @Published private(set) var visibleTranscript: [MeetingTranscriptSegment] = []
  @Published private(set) var echoCount = 0
  /// The meeting whose summary is being generated, possibly not the selected one.
  @Published private(set) var summarizingID: UUID?
  @Published private(set) var summaryAvailability: MeetingSummaryAvailability?
  let captureSupported: Bool
  private let store: MeetingStore
  private let recognizer: any SpeechRecognizing
  private let summarizer: any MeetingSummarizing
  private let makeCapture: () throws -> any MeetingAudioRecording
  private let reserveSpeech: () -> Bool
  private let releaseSpeech: () -> Void
  private let vocabulary: @MainActor () -> MeetingVocabulary
  private let recoveryRetryDelay: Duration
  private var recorder: (any MeetingAudioRecording)?
  private var drainTask: Task<Void, Never>?
  private var drainRequested = false
  private var lastSaved: MeetingRecord?
  private var loadTask: Task<Void, Never>?
  private var writeTask: Task<Bool, Never>?
  private var captureStartFailure: String?
  private var activeCaptureID: UUID?
  private var summaryTask: Task<String, Error>?
  private var recoveryTask: Task<Void, Never>?
  private var transcriptionAttempts: [UUID: Int] = [:]

  static var systemSupportsCapture: Bool {
    if #available(macOS 15.0, *) { return true }
    return false
  }

  init(
    store: MeetingStore = MeetingStore(), recognizer: any SpeechRecognizing,
    summarizer: any MeetingSummarizing = LocalMeetingSummarizer(),
    makeCapture: @escaping () throws -> any MeetingAudioRecording = {
      if #available(macOS 15.0, *) { return MeetingAudioCapture() }
      throw MeetingError.capture(
        "Meeting capture requires macOS 15 or later. Dictation and quick notes remain available.")
    }, reserveSpeech: @escaping () -> Bool, releaseSpeech: @escaping () -> Void,
    vocabulary: @escaping @MainActor () -> MeetingVocabulary = { .empty },
    captureSupported: Bool = MeetingModel.systemSupportsCapture,
    recoveryRetryDelay: Duration = .seconds(15)
  ) {
    self.store = store
    self.recognizer = recognizer
    self.summarizer = summarizer
    self.makeCapture = makeCapture
    self.reserveSpeech = reserveSpeech
    self.releaseSpeech = releaseSpeech
    self.vocabulary = vocabulary
    self.captureSupported = captureSupported
    self.recoveryRetryDelay = recoveryRetryDelay
  }

  var busy: Bool { phase != .idle }
  var dirty: Bool { draft != lastSaved }
  var summarizingSelection: Bool { summarizingID != nil && summarizingID == draft?.id }
  var failedSegmentCount: Int { draft?.transcript.filter(\.isFailed).count ?? 0 }
  var visibleMeetings: [MeetingRecord] {
    meetings.filter {
      ($0.deletedAt != nil) == showingDeleted
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || $0.notes.localizedCaseInsensitiveContains(search)
          || $0.transcript.contains {
            $0.isSpeech && $0.text.localizedCaseInsensitiveContains(search)
          })
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

  /// Saves the draft. A save already in flight is awaited first, then the latest draft is written.
  @discardableResult
  func save() async -> Bool {
    await exclusively { [self] in
      guard let draft, dirty else { return true }
      saving = true
      defer { saving = false }
      do {
        try await store.save(draft)
        lastSaved = draft
        remember(draft)
        return true
      } catch {
        self.error = error.localizedDescription
        return false
      }
    }
  }

  /// Runs one store write at a time. Draft saves and background summary writes pass through
  /// here, so a stored record is never replaced by an older copy.
  private func exclusively(_ write: @escaping @MainActor () async -> Bool) async -> Bool {
    while let writeTask { _ = await writeTask.value }
    let task = Task { @MainActor in
      let result = await write()
      writeTask = nil
      return result
    }
    writeTask = task
    return await task.value
  }

  private func remember(_ record: MeetingRecord) {
    if let index = meetings.firstIndex(where: { $0.id == record.id }) {
      meetings[index] = record
    } else {
      meetings.insert(record, at: 0)
    }
  }

  func select(_ meeting: MeetingRecord) async {
    guard !busy else {
      error = "Stop the current meeting before opening another."
      return
    }
    guard await saveBeforeTransition(), !busy else { return }
    let saved = meetings.first { $0.id == meeting.id }
    draft = saved
    lastSaved = saved
    error = nil
    transcriptionFailed = false
  }

  func showDeleted(_ deleted: Bool) async {
    guard !busy, await saveBeforeTransition() else { return }
    showingDeleted = deleted
    if let draft, (draft.deletedAt != nil) != deleted {
      self.draft = nil
      lastSaved = nil
    }
  }

  /// Moves the selected meeting to Recently Deleted, or restores it. Audio and text are kept.
  func setDeleted(_ deleted: Bool) async {
    guard let current = draft else { return }
    guard !busy, summarizingID != current.id else {
      error = "Finish the current meeting activity, then try again."
      return
    }
    draft?.deletedAt = deleted ? Date() : nil
    if await save() {
      draft = nil
      lastSaved = nil
    } else {
      draft?.deletedAt = current.deletedAt
    }
  }

  func start() async {
    guard captureSupported else {
      error =
        "Meeting recording requires macOS 15 or later. Dictation and quick notes remain available."
      return
    }
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
    Task { await refreshSummaryAvailability() }
    var created: UUID?
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
      showingDeleted = false
      draft = MeetingRecord(
        title: Date().formatted(.dateTime.month(.abbreviated).day()) + " meeting")
      lastSaved = nil
      guard await save(), let draft else {
        throw MeetingError.storage("The meeting could not be created. Check available disk space.")
      }
      created = draft.id
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
      if let created { await discardUnusedMeeting(created) }
    }
  }

  /// A meeting whose capture never started has nothing to recover; don't leave it "Interrupted".
  private func discardUnusedMeeting(_ id: UUID) async {
    guard let current = draft, current.id == id, current.notes.isEmpty,
      current.transcript.isEmpty, current.summary.isEmpty, !dirty
    else { return }
    do {
      try await store.discardUnused(id)
      meetings.removeAll { $0.id == id }
      draft = nil
      lastSaved = nil
    } catch {
      // Keep the record: something unexpected is in its folder and must stay recoverable.
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
    let saved = await save()
    phase = .idle
    releaseSpeech()
    if summarize && saved && !transcriptionFailed && summarizingID == nil {
      await generateSummary()
    }
  }

  /// Sleep, permission loss and similar events stop capture. If transcription of the saved
  /// chunks fails meanwhile, it is retried automatically once the Mac is awake again.
  func interrupt(_ message: String) async {
    guard phase == .preparing || phase == .recording || phase == .finishing else { return }
    error = message
    if phase == .preparing {
      captureStartFailure = message
      return
    }
    await stop(summarize: false)
    if transcriptionFailed, let id = draft?.id { scheduleRecovery(for: id) }
  }

  private func scheduleRecovery(for id: UUID) {
    recoveryTask?.cancel()
    let delay = recoveryRetryDelay
    recoveryTask = Task { [weak self] in
      for _ in 0..<3 {
        // The suspending clock does not advance during sleep, so this waits for awake time.
        do { try await Task.sleep(for: delay, clock: .suspending) } catch { return }
        guard let self, self.transcriptionFailed, self.draft?.id == id else { return }
        if self.phase == .idle {
          await self.recoverTranscript()
          if !self.transcriptionFailed { return }
        }
      }
    }
  }

  func recoverTranscript() async {
    guard phase == .idle, draft != nil else { return }
    guard reserveSpeech() else {
      error = "Finish dictating, then try again."
      return
    }
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
    // Chunks saved as failures get one more attempt; failing again restores the placeholder.
    if let failed = draft?.transcript.filter(\.isFailed), !failed.isEmpty {
      for segment in failed {
        transcriptionAttempts[segment.id] = Self.maximumTranscriptionAttempts - 1
      }
      draft?.transcript.removeAll { $0.isFailed }
    }
    await drain()
    if draft?.endedAt == nil { draft?.endedAt = Date() }
    _ = await save()
  }

  func refreshSummaryAvailability() async {
    summaryAvailability = await summarizer.availability()
  }

  /// Summaries run in the background: other meetings can be opened or recorded meanwhile,
  /// and the result is written to the summarized meeting's stored record.
  func generateSummary() async {
    guard summarizingID == nil else {
      error = "Another summary is being generated. Try again when it finishes."
      return
    }
    guard phase == .idle, !transcriptionFailed, let original = draft else { return }
    let task = Task { [store, summarizer] in
      try Task.checkCancellation()
      guard try await store.pendingAudioFiles(for: original).isEmpty else {
        throw MeetingError.summary("Finish recovering the transcript before generating a summary.")
      }
      try Task.checkCancellation()
      return try await summarizer.summarize(original)
    }
    // Own cancellation before publishing the state that reveals the Cancel button.
    summaryTask = task
    summarizingID = original.id
    error = nil
    defer {
      summarizingID = nil
      summaryTask = nil
    }
    do {
      let text = try await task.value
      guard !task.isCancelled else { throw CancellationError() }
      try await apply(summary: text, to: original)
    } catch is CancellationError {
      report("Summary cancelled. Your transcript and previous summary are preserved.", original)
    } catch { report(error.localizedDescription, original) }
  }

  private func report(_ message: String, _ meeting: MeetingRecord) {
    error = draft?.id == meeting.id ? message : "“\(meeting.title)”: \(message)"
  }

  /// Notes may change during generation; only a different transcript invalidates the result.
  private func apply(summary text: String, to original: MeetingRecord) async throws {
    let changed = MeetingError.summary(
      "The transcript changed while summarizing. Generate again to include it.")
    if draft?.id == original.id {
      guard draft?.transcript == original.transcript else { throw changed }
      draft?.summary = text
      guard await save() else {
        throw MeetingError.summary("The summary could not be saved. Your transcript is safe.")
      }
      return
    }
    var failure: Error?
    _ = await exclusively { [self] in
      do {
        guard var latest = try await store.record(id: original.id),
          latest.transcript == original.transcript
        else { throw changed }
        let previous = latest.summary
        latest.summary = text
        try await store.save(latest)
        remember(latest)
        // The meeting may have been opened while the summary was written.
        if draft?.id == latest.id {
          if lastSaved?.summary == previous { lastSaved?.summary = text }
          if draft?.summary == previous { draft?.summary = text }
        }
        return true
      } catch {
        failure = error
        return false
      }
    }
    if let failure { throw failure }
  }

  func cancelSummary() { summaryTask?.cancel() }

  func discardChanges() {
    guard phase == .idle, !saving, !summarizingSelection else { return }
    // Keep storage failures and captured audio available for explicit recovery.
    draft = lastSaved
  }

  func prepareToClose() async -> Bool {
    // Closing a window during a meeting only hides it; capture remains explicit in the menu.
    await saveBeforeTransition()
  }

  private func saveBeforeTransition() async -> Bool {
    guard await save() else { return false }
    return !dirty
  }

  func prepareToQuit() async -> Bool {
    guard phase != .preparing && phase != .stopping else {
      error = "Wait for the current meeting operation to finish before quitting."
      return false
    }
    guard phase != .transcribing else {
      error =
        "Vani is finishing this meeting’s transcript. Quit again in a moment; saved audio is safe."
      return false
    }
    // Summaries are regenerable: cancel instead of refusing to quit.
    if let summaryTask {
      summaryTask.cancel()
      _ = try? await summaryTask.value
    }
    recoveryTask?.cancel()
    if phase == .recording || phase == .finishing { await stop(summarize: false) }
    guard phase == .idle else { return false }
    return await prepareToClose()
  }

  /// Removes saved audio once every chunk has a durable transcript. Chunks saved as failures
  /// still hold the only copy of that speech, so they require `includingFailed`.
  func clearAudio(includingFailed: Bool = false) async {
    guard !busy else {
      error = "Stop the meeting before removing its audio."
      return
    }
    guard await saveBeforeTransition(), let draft else { return }
    do {
      guard let durable = try await store.record(id: draft.id),
        try await store.pendingAudioFiles(for: durable).isEmpty
      else {
        throw MeetingError.storage("Recover all remaining transcript audio before removing it.")
      }
      guard includingFailed || !durable.transcript.contains(where: \.isFailed) else {
        throw MeetingError.storage(
          "Some audio couldn’t be transcribed. Recover transcript to retry it, or confirm removing it."
        )
      }
      try await store.deleteAudio(for: draft.id)
    } catch { self.error = error.localizedDescription }
  }

  private func refreshTranscript() {
    let ordered = (draft?.transcript ?? []).sorted {
      $0.offset == $1.offset
        ? $0.source == .microphone && $1.source == .system : $0.offset < $1.offset
    }
    echoCount = ordered.filter { $0.isEcho && !$0.text.isEmpty }.count
    visibleTranscript = ordered.filter {
      $0.isSpeech || $0.isFailed || (showingEchoes && $0.isEcho && !$0.text.isEmpty)
    }
  }

  private func requestDrain() {
    guard !transcriptionFailed, phase == .recording || phase == .preparing else { return }
    guard drainTask == nil else {
      // A chunk arriving while drain lists files must not wait for the next chunk.
      drainRequested = true
      return
    }
    drainTask = Task { [weak self] in
      guard let self else { return }
      repeat {
        drainRequested = false
        await drain()
      } while drainRequested && !transcriptionFailed
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
        var text = ""
        var failed = false
        if audio.duration >= Self.minimumSpeechDuration,
          audio.loudestFrameRootMeanSquare >= Self.silenceThreshold
        {
          let vocabulary = vocabulary()
          do {
            let result = try await recognizer.transcribe(
              audio, context: vocabulary.recognitionContext)
            text = vocabulary.process(result.text)
          } catch {
            let attempts = transcriptionAttempts[chunk.id, default: 0] + 1
            transcriptionAttempts[chunk.id] = attempts
            guard attempts >= Self.maximumTranscriptionAttempts else { throw error }
            failed = true
          }
        }
        guard draft?.id == current.id else { return }
        if let transcript = draft?.transcript, !transcript.contains(where: { $0.id == chunk.id }) {
          let segment = MeetingTranscriptSegment(
            id: chunk.id, source: chunk.source, offset: chunk.offset, duration: audio.duration,
            text: text, failed: failed ? true : nil)
          // Re-evaluated on every arrival, so a Mac-audio segment can mark an earlier mic echo.
          draft?.transcript = MeetingEchoDetector.marking(transcript + [segment])
        }
        guard await save() else {
          throw MeetingError.storage(
            "The transcript could not be saved. Captured audio is preserved for recovery.")
        }
        if !failed { transcriptionAttempts[chunk.id] = nil }
      }
    } catch {
      transcriptionFailed = true
      self.error =
        "Live transcription paused: \(error.localizedDescription). Captured audio remains on this Mac; use Recover transcript after stopping."
    }
  }
}

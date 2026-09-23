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
  /// A chunk is tried this many times in a row before it is saved as a visible failure segment.
  static let maximumTranscriptionAttempts = 3
  /// Disk space left untouched for meeting records, transcripts and the rest of the system.
  nonisolated static let diskReserveBytes: Int64 = 256 * 1_048_576
  /// A meeting does not start with less recordable time than this, and warns when it drops
  /// below it while recording.
  nonisolated static let minimumRecordableTime: TimeInterval = 10 * 60
  /// How long before the four-hour limit the user is told recording will stop.
  nonisolated static let durationLimitWarning: TimeInterval = 10 * 60

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
  /// A non-fatal heads-up while preparing or recording: low disk space or the time limit.
  @Published private(set) var notice: String?
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
  private var echoDetector = MeetingEchoDetector()
  private let transcriptionRetryDelay: Duration
  private let availableDiskSpace: @Sendable (URL) -> Int64?
  private let monitorInterval: Duration
  private let now: @MainActor () -> ContinuousClock.Instant
  private var monitorTask: Task<Void, Never>?
  private var recordingStartedAt: ContinuousClock.Instant?
  private var warnedAboutDisk = false
  private var warnedAboutDuration = false

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
    recoveryRetryDelay: Duration = .seconds(15),
    transcriptionRetryDelay: Duration = .milliseconds(500),
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = {
      MeetingModel.availableDiskSpace(at: $0)
    },
    monitorInterval: Duration = .seconds(30),
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
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
    self.transcriptionRetryDelay = transcriptionRetryDelay
    self.availableDiskSpace = availableDiskSpace
    self.monitorInterval = monitorInterval
    self.now = now
  }

  var busy: Bool { phase != .idle }
  var dirty: Bool { draft != lastSaved }
  var summarizingSelection: Bool { summarizingID != nil && summarizingID == draft?.id }
  var failedSegmentCount: Int { draft?.transcript.filter(\.isFailed).count ?? 0 }
  /// Saved audio that still lacks a real transcript after an interruption.
  private var needsRecovery: Bool { transcriptionFailed || failedSegmentCount > 0 }
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
    notice = nil
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
      capture.setWarningHandler { [weak self] message in
        Task { @MainActor in
          guard let self, self.activeCaptureID == captureID else { return }
          self.error = message
        }
      }
      // Check space before anything is written, so a full disk is explained up front.
      notice = try diskPreflight()
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
      startMonitoring()
      if captureStartFailure != nil { await stop(summarize: false) }
    } catch {
      self.error = error.localizedDescription
      notice = nil
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
    stopMonitoring()
    draft?.endedAt = Date()
    phase = .transcribing
    await drainTask?.value
    // Try again even if live transcription paused: the failure may have been transient.
    transcriptionFailed = false
    await drain()
    let saved = await save()
    phase = .idle
    releaseSpeech()
    if summarize && saved && !transcriptionFailed && summarizingID == nil,
      draft?.transcript.contains(where: \.isSpeech) == true
    {
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
    if needsRecovery, let id = draft?.id { scheduleRecovery(for: id) }
  }

  private func scheduleRecovery(for id: UUID) {
    recoveryTask?.cancel()
    let delay = recoveryRetryDelay
    recoveryTask = Task { [weak self] in
      for _ in 0..<3 {
        // The suspending clock does not advance during sleep, so this waits for awake time.
        do { try await Task.sleep(for: delay, clock: .suspending) } catch { return }
        guard let self, self.needsRecovery, self.draft?.id == id else { return }
        if self.phase == .idle {
          await self.recoverTranscript()
          if !self.needsRecovery { return }
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
    // Chunks saved as failures are tried again; failing again restores the failure segment.
    draft?.transcript.removeAll { $0.isFailed }
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

  // MARK: - Disk space and duration

  /// Space available for new files on the volume holding `url` (or its nearest existing
  /// parent), counting space macOS can reclaim for important use.
  nonisolated static func availableDiskSpace(at url: URL) -> Int64? {
    var candidate = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: candidate.path),
      candidate.pathComponents.count > 1
    {
      candidate.deleteLastPathComponent()
    }
    guard
      let values = try? candidate.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
      ])
    else { return nil }
    return values.volumeAvailableCapacityForImportantUsage
      ?? values.volumeAvailableCapacity.map(Int64.init)
  }

  /// Seconds of two-source meeting audio that fit in `free` bytes above the reserve.
  static func recordableTime(freeBytes free: Int64) -> TimeInterval {
    Double(max(0, free - diskReserveBytes)) / Double(MeetingLimits.audioBytesPerSecond)
  }

  static func formatted(bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func formatted(duration: TimeInterval) -> String {
    let minutes = Int(duration / 60)
    return minutes >= 60
      ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
  }

  /// Refuses to start when the disk cannot hold ten minutes of audio; otherwise returns a
  /// notice when the disk cannot hold a full four-hour meeting. Unknown space is not an error.
  private func diskPreflight() throws -> String? {
    guard let free = availableDiskSpace(store.directory) else { return nil }
    let recordable = Self.recordableTime(freeBytes: free)
    let hour = Int64(MeetingLimits.audioBytesPerSecond) * 3600
    guard recordable >= Self.minimumRecordableTime else {
      throw MeetingError.storage(
        "Only \(Self.formatted(bytes: free)) is free on this Mac. Free up disk space before recording: each hour of meeting audio needs about \(Self.formatted(bytes: hour))."
      )
    }
    guard recordable < MeetingLimits.maximumDuration else { return nil }
    return
      "Free disk space holds about \(Self.formatted(duration: recordable)) of meeting audio (\(Self.formatted(bytes: free)) free). Vani stops recording safely before the disk fills."
  }

  private func startMonitoring() {
    recordingStartedAt = now()
    warnedAboutDisk = false
    warnedAboutDuration = false
    monitorTask?.cancel()
    let interval = monitorInterval
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        guard let self, !Task.isCancelled else { return }
        await self.checkDiskAndDuration()
      }
    }
  }

  private func stopMonitoring() {
    monitorTask?.cancel()
    monitorTask = nil
    recordingStartedAt = nil
    notice = nil
  }

  /// Warns before the disk fills or the four-hour limit is reached, and stops recording
  /// cleanly, keeping everything captured, when only the reserve is left.
  func checkDiskAndDuration() async {
    guard phase == .recording else { return }
    if let free = availableDiskSpace(store.directory) {
      let recordable = Self.recordableTime(freeBytes: free)
      if recordable <= 0 {
        // Stopping cancels this monitor; finish the stop outside it so transcription of the
        // final chunks is not cancelled with it.
        await Task { await self.stop(summarize: false) }.value
        error =
          "Recording stopped because the disk is almost full (\(Self.formatted(bytes: free)) free). Everything captured so far is saved."
        return
      }
      if recordable < Self.minimumRecordableTime, !warnedAboutDisk {
        warnedAboutDisk = true
        notice =
          "Disk space is low: about \(Self.formatted(duration: recordable)) of recording remains. Free up space, or stop the meeting; captured audio is saved."
        return
      }
    }
    if let started = recordingStartedAt, !warnedAboutDuration {
      let elapsed = (now() - started) / .seconds(1)
      let remaining = MeetingLimits.maximumDuration - elapsed
      if remaining <= Self.durationLimitWarning {
        warnedAboutDuration = true
        notice =
          "This meeting reaches the four-hour limit in about \(Self.formatted(duration: max(60, remaining))). Recording then stops and everything captured is saved."
      }
    }
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
        guard let file = try await store.pendingAudioFiles(for: current).first,
          let identity = MeetingAudioChunk.identity(fromFileName: file.lastPathComponent)
        else { return }
        let segment = await transcribeChunk(file, identity: identity, meetingID: current.id)
        guard draft?.id == current.id else { return }
        if let transcript = draft?.transcript, !transcript.contains(where: { $0.id == segment.id })
        {
          // A Mac-audio segment can also mark an earlier, overlapping microphone echo.
          draft?.transcript = echoDetector.adding(segment, to: transcript)
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

  /// Reads and transcribes one chunk, retrying in place with a short backoff. After the last
  /// failed attempt, whether reading or recognition failed, it returns a failure segment so the
  /// following chunks continue; the chunk's audio file is kept for Recover transcript.
  private func transcribeChunk(
    _ file: URL, identity: MeetingAudioChunk.Identity, meetingID: UUID
  ) async -> MeetingTranscriptSegment {
    var source = identity.source ?? .system
    var offset = identity.offset ?? 0
    var duration: TimeInterval = 0
    for attempt in 1...Self.maximumTranscriptionAttempts {
      do {
        let chunk = try await store.readAudio(file, meetingID: meetingID)
        let audio = try chunk.audio()
        (source, offset, duration) = (chunk.source, chunk.offset, audio.duration)
        var text = ""
        if audio.duration >= Self.minimumSpeechDuration,
          audio.loudestFrameRootMeanSquare >= Self.silenceThreshold
        {
          let vocabulary = vocabulary()
          let result = try await recognizer.transcribe(
            audio, context: vocabulary.recognitionContext)
          text = vocabulary.process(result.text)
        }
        return MeetingTranscriptSegment(
          id: identity.id, source: source, offset: offset, duration: duration, text: text)
      } catch {
        if attempt < Self.maximumTranscriptionAttempts {
          try? await Task.sleep(for: transcriptionRetryDelay * attempt)
        }
      }
    }
    return MeetingTranscriptSegment(
      id: identity.id, source: source, offset: offset, duration: duration, text: "", failed: true)
  }
}

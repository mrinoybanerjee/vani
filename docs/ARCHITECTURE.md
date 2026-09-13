# Architecture

Vani is a Swift 6 package with two production targets. This diagram shows the
dictation and correction branch; the optional Notes and Meetings branches are described below.

```text
Vani (SwiftUI/AppKit, @MainActor)
  -> AppCoordinator
     -> TeachWindowController (focusable correction window)
     -> DictationSession actor
        -> AVAudioEngineCapture actor
        -> FluidAudioSpeechRecognizer actor
        -> TextPipeline value type
        -> SystemTextInserter (@MainActor)
        -> TranscriptRecovery actor
        -> TranscriptHistoryStore actor
```

## State ownership

`DictationSession` is the only owner of the dictation phase. Its explicit state
machine rejects duplicate and out-of-order events. UI receives immutable
`SessionSnapshot` values and cannot mutate the state directly.

`AppCoordinator` owns the standalone Teach Vani window. Reopening Teach brings the
existing window forward so an unfinished correction is preserved, and application
activation restores keyboard focus to its editor.

The coordinator lazily owns a separate `NotesWindowController`. Its main-actor
`NotesModel` owns the editable draft and UI state; a `NoteStore` actor owns local
file operations. Save as Note reads the selected transcript without changing the
dictation session. Switching notes, closing, and quitting first save the draft;
a failed save prevents the transition. See [Local Notes](NOTES_DESIGN.md).

The app moves through `setup`, `preparing`, `ready`, `listening`, `transcribing`,
`inserting`, and `recoverableError`. Permission loss, sleep, audio-route changes,
and termination have explicit transitions.

## Audio path

`AVAudioEngineCapture` installs one microphone tap. The tap copies samples into a
duration-bounded, paged buffer protected by `OSAllocatedUnfairLock`. Three minutes of
pages are reserved before capture; one additional minute is reserved off the real-time
thread for each minute that recording continues, up to 20 minutes. The audio callback
does not allocate, log, perform model work, or access the network. Captured audio is
drained from the page buffer and converted to mono 16 kHz float samples after recording.
Input devices are accepted through 48 kHz; higher hardware rates are rejected before
capture so the documented 20-minute memory ceiling remains bounded.

At 19 minutes the session publishes a warning. At 20 minutes it owns the same
stop-transcribe-insert path used by a shortcut release, so only one caller can stop the
microphone. If the bounded buffer reaches capacity first, its retained prefix is still
returned for transcription and marked in metadata-only diagnostics instead of being
discarded.

If post-capture sample-rate conversion fails, the raw snapshot remains in memory behind
an explicit retry action. Route changes and sleep events do not discard a snapshot
waiting for recovery. If sleep, permission loss, or a route change interrupts an active
recording, Vani stops and retains its captured prefix for an explicit transcription
retry.

## Speech and text

`FluidAudioSpeechRecognizer` loads the English Parakeet TDT v2 Core ML pipeline and
uses CPU plus Neural Engine compute units. Vani downloads only an allowlist of exact
paths from a pinned model revision into private staging. Before atomic installation
and loading, it verifies the exact file set, sizes, and SHA-256 digests. `TextPipeline`
performs conservative whitespace cleanup, user-defined exact phrase replacement,
one-pass snippet expansion, and optional deterministic Smart Formatting. Formatting
recognizes a small fixed English command set; it does not use an LLM, surrounding
application context, or network access.

Opt-in personalization stores only confirmed correction spans in a separate versioned,
bounded, atomic local profile. The profile actor serializes teach, delete, and reset
transactions and quarantines unsafe data. Deterministic learned corrections run before
the manual dictionary, while manual dictionary and snippet collisions are excluded.
Confirming a replacement again preserves its identity and uses the latest explicit casing.
After two confirmations, up to 50 ranked terms can be passed to an optional experimental pinned CTC
110M model for conservative acoustic rescoring. Any auxiliary-model failure returns the
successful base TDT transcript. FluidAudio 0.15.5's rescoring path is disabled in Debug
builds because that dependency enables content-bearing debug logs there.

## Insertion contract

Vani records the focused process before capture and refuses insertion if the foreground
application changes. At insertion time it re-resolves that process's focused
Accessibility element, because dynamic web and rich-text controls can replace their AX
objects without changing the user's target. A readable element is verification evidence,
not a prerequisite for delivery. Apple's secure-text-field subrole is checked before
capture, before pasteboard access, and at the final paste boundary.

Vani snapshots the pasteboard, writes the transcript, and sends one paced paste command
to the captured process. It polls app-scoped Accessibility state for up to two seconds
for an observable value, selection, range, or character-count change. Full control-value
reads are capped at one million characters; larger documents use bounded range and count
evidence. Vani restores the snapshot only after verification and only if another process
did not change the pasteboard. An unobservable paste leaves the transcript on the
clipboard and presents a neutral manual-paste hint; it is never reported as verified.

## Persistence

Settings are Codable values stored in `UserDefaults`. Optional history uses an
atomic local JSON file, is bounded, and quarantines corrupt data. Dictation recovery audio and
the latest failed or successful dictation transcript are memory-only. Diagnostics are bounded
and metadata only.

The personalization profile uses `personalization.json` in Application Support with a
1 MiB pre-read ceiling, schema version, private permissions, atomic writes, and corrupt
file quarantine. It is independent of transcript history and contains no audio.
Learning and removal can start fresh only after corrupt data is successfully preserved;
a failed quarantine propagates the storage error and prevents replacement of the original file.

Notes use versioned `Notes/notes.json`, bounded to 1,000 records, 1 MiB text and
4 KiB title per note, and a 16 MiB encoded file. Atomic owner-only writes retain
`notes.backup.json`; explicit backup restoration preserves the current file.
Recently Deleted is a reversible field change, not a purge. The notebook has no
audio capture, inference, network activity, or dependency on transcript history.

## Dependency boundary

FluidAudio is the only external package. Its exact source revision and transitive
graph are locked by SwiftPM. Speech model artifacts are pinned independently by revision
and SHA-256 manifest. Apple frameworks provide audio, UI, Accessibility, global
keyboard events, login items, logging, and code signing integration. Meeting summaries
use a separately installed Ollama runtime and its `qwen3:4b` model tag; those are not
bundled or covered by Vani's speech-model manifest.

## Meeting boundary

`AppCoordinator` lazily owns `MeetingWindowController → MeetingModel → MeetingStore`.
A synchronous reservation protects the existing `FluidAudioSpeechRecognizer` from overlapping
dictation and meeting work, including quit preflight. `MeetingAudioCapture` uses ScreenCaptureKit
on macOS 15+ with microphone and system audio outputs on one serial work queue. There is no
video output. Chunk conversion and atomic persistence run off the main actor; transcription
drains one saved file at a time through the existing recognizer. Capture callbacks carry a
session identity, and a stopped stream can retry a failed final flush without restarting capture.

`LocalMeetingSummarizer` sends bounded transcript batches to a fixed loopback-only Ollama
endpoint. It validates structured output against exact transcript quotes and renders separate
summary, decisions and actions. Personal notes are not overwritten by generation. The existing
quick-note schema and dictation state machine do not migrate. See [MEETINGS_DESIGN.md](MEETINGS_DESIGN.md)
for persistence limits, failure behavior and local runtime requirements.

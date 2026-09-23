# Local meeting notes

Approved September 12, 2026: the user clarified that Notes must capture live meetings,
produce meeting notes and summaries, and keep all processing on the Mac.

## Product contract

**Meetings** is distinct from quick **Notes**. One explicit start records microphone and
other Mac audio after a disclosure and macOS permission approval. No bot joins a call.
Use headphones and inform participants. No video output is registered. Native microphone
and Screen & System Audio Recording permission are required; macOS 15+ is required for
combined capture. Existing dictation and quick notes continue to support macOS 14.

The workspace keeps My notes, Transcript and Summary separate. Transcript updates arrive
in chunks of 15–24 seconds: after 15 seconds each source is cut in the quietest 200 ms window
(immediately at a near-silent one, otherwise the quietest before 24 seconds), so words are not
split. Labels are "Me" (microphone) and "Others" (Mac audio); they identify sources, not people.
Chunks use the user's dictionary and, when personalization is enabled, learned corrections and
acoustic terms. Snippets and Smart Formatting are never applied to meetings. A chunk is skipped
as silence only when its loudest 30 ms frame stays below a low RMS threshold, so short quiet
phrases inside long silences are still transcribed.

Without headphones the microphone also hears other participants. Echo marking is deliberately
conservative: a microphone segment is echo only when it has at least 8 words and at least 90% of
them, with no more than 2 exceptions, are covered by runs of three or more words from Mac-audio
segments whose time span overlaps its own (0.5 s capture slack), whichever arrives first. Short
replies that repeat a question, and segments mixing the user's own words with echo, stay visible
and are summarized. Echo lines are kept on disk, hidden by default with a toggle to show them,
and excluded from summaries and exports. Only microphone segments overlapping a new segment are
re-evaluated, with normalized words cached per segment.

Stop flushes the final chunks, finishes transcription, saves, then generates a summary.
Closing the window hides it while capture continues; the menu exposes the active meeting.
Quitting must finish capture and save successfully; while a transcript is finishing, quit is
refused with an explanation. A running summary is cancelled on quit, because it can be
regenerated. No recording starts automatically. If sleep or permission loss interrupts a meeting
and transcription of saved chunks fails, it is retried automatically after the Mac is awake.

## Small, explicit architecture

```text
AppCoordinator: exclusive speech reservation + quit preflight
  WorkspaceWindowController / WorkspaceModel: shared window, navigation and close save barriers
    MeetingView: library / authored notes / transcript / summary / export
      MeetingModel: prepare → record → stop → transcribe → summarize → idle
        MeetingAudioCapture: ScreenCaptureKit audio outputs, serial work queue
        MeetingStore actor: per-meeting atomic record + completed audio chunks
        existing FluidAudioSpeechRecognizer: English inference on this Mac
        LocalMeetingSummarizer: fixed loopback Ollama → validated summary text
```

The capture handle remains owned after a failed stop. If the stream stopped but final
storage failed, Finish saving retries the flush without restarting capture. Each callback
belongs to one capture identity, so late callbacks cannot stop a newer meeting. Transcription
processes one persisted chunk at a time, with chunk IDs making recovery idempotent. Dictation
is temporarily unavailable while meetings use the shared recognizer; its insertion path is unchanged.

## Persistence and recovery

`Application Support/Vani/Meetings/<UUID>/meeting.json` stores title, dates, personal notes,
source segments and summary. Each save retains the previous valid record in `meeting.backup.json`.
Directories use mode 0700; atomic files use 0600. Files are not encrypted by the app.
Corrupt files are preserved and surfaced as errors, never silently replaced. An empty abandoned
UUID directory from a failed initial creation does not block other meetings; orphaned audio or
backups are preserved and fail closed. A hidden temporary file left by a crash is ignored so it
cannot hide other meetings, and removed when meetings load once it is more than an hour old. Manual file recovery remains
necessary for corrupt meeting metadata; the app does not silently restore an older record.
While the stored file still matches the last record the store wrote, the backup is written from
memory instead of being read and decoded again; any outside change triggers full validation.
If capture fails to start, the just-created record is removed only when it has no audio, notes,
transcript or summary. Deleting a meeting moves it to Recently Deleted (`deletedAt`); its notes,
transcript, summary and audio are kept and it can be restored.

Records are limited to 8 MiB, titles to 4 KiB, notes and summaries to 1 MiB each, and transcripts
to 1,440 unique segments with validated offsets and sizes. Audio chunks are bounded binary
property lists containing 16 kHz mono Float PCM. New chunk filenames are
`<chunk ID>_<mic|sys>_<offset ms>.vani-audio`, so pending audio is ordered, and an unreadable
chunk reported, without decoding audio; older chunks named by bare ID are decoded once for their
offset. A name must agree with the chunk it holds. Other files are ignored and never deleted. Completed
chunks are durable before transcription. The unfinished tail (up to 24 seconds per source) can
be lost on process crash. A two-hour recording contains roughly 880 MiB of uncompressed audio
when both sources are continuously active; keep sufficient disk space available.

Notes autosave after a 600 ms pause. Close, navigation and audio removal pass through a save
barrier. A save failure retains the draft for retry or export. When idle, explicitly
confirming Discard Changes after a save failure restores the
last saved meeting without writing, hiding the error, or deleting captured audio. Export first
to keep unsaved edits; closing never discards automatically. Recover transcript retries saved
chunks in recording order (offset, then ID); already persisted segment IDs are skipped. Each
chunk is tried up to three times in place with a short backoff; if reading or transcribing it
still fails, a failure segment ("Couldn't transcribe 0:40–1:00") is saved and the following
chunks continue. Its audio is kept and Recover transcript retries it. A storage failure pauses
live transcription; Stop always tries again.
Remove saved audio requires every captured chunk to have a durable transcript, and a user
confirmation; a second, explicit confirmation is required while failure segments still depend on
their audio. It keeps notes, transcript and summary. No automatic audio deletion or silent
truncation occurs.

## Local summaries

Ollama must already be running with `qwen3:4b` installed (approximately 2.5 GB download).
Before a meeting starts and when the Summary tab opens, Vani checks
`http://127.0.0.1:11434/api/tags` without blocking and shows a quiet hint if the model is missing;
recording never depends on it. Vani sends bounded transcript batches to
`http://127.0.0.1:11434/api/generate`. Both requests refuse redirects, disable system proxies, use
an ephemeral session and cap each response at 256 KiB. Vani checks completion and structured
output, reports output cut off at the model's length limit, keeps the model loaded between
batches and asks Ollama to unload it with the final request, or with an explicit unload request
after a failure, cancellation or skipped consolidation. There is no cloud fallback or
configurable remote URL.

The model receives the transcript (without echo lines or failure segments) and the meeting's own
notes, at most 4,000 characters, delimited and marked as untrusted data. Notes indicate which
topics the user found important; they are never accepted as evidence. Every generated summary,
decision and action still requires a quote that matches its cited transcript segment after
case, punctuation and whitespace are normalized (whole words only); a quote needs at least three
words or twelve characters. Unsupported items are dropped
and counted in a short note; the summary fails only when every proposed item is unsupported.
When a transcript needs more than one batch, a final consolidation pass merges duplicates into at
most 8 summary items, 8 decisions and 10 actions. Each merged item must cite validated items of
the same section by number and is shown with every cited quote and time. A merged item that adds
a number or capitalized name absent from its cited items is rejected, and any validated item left
uncited is kept as it was, so consolidation never drops evidence. Consolidation is skipped when a
conservative token estimate of the prompt plus answer exceeds the 8,192-token context. If it is
skipped or fails, the de-duplicated batch items are used. An unavailable model produces an error and preserves the
previous summary. Summaries run in the background: other meetings can be opened or recorded,
and the result is written to the summarized meeting's latest stored record. Notes edited during
generation are kept; a changed transcript invalidates the result. Quoted evidence is a review aid,
not proof against all model errors.

## Validation boundaries

Tests cover native note editing, save/reopen, capture lifecycle, final-chunk transcription,
ASR retry, durable-audio deletion, failed stop/flush, stale callbacks, corrupt storage, private
permissions, invalid data and local summary fixtures. Review also covers the untouched dictation
regression suite. Hardware capture, long meetings, device changes, macOS permissions and VoiceOver
need actual-machine acceptance; unit fixtures are not evidence that a real call was captured.

There is no calendar integration, automatic meeting detection, pause/resume, person-level diarization,
or cross-meeting chat in this version. Those require measured designs rather than dormant abstractions.

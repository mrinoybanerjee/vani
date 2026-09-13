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
in roughly 20-second chunks; labels identify microphone or Mac audio, not individual people.
Stop flushes the final chunks, finishes transcription, saves, then generates a summary.
Closing the window hides it while capture continues; the menu exposes the active meeting.
Quitting must finish capture and save successfully. No recording starts automatically.

## Small, explicit architecture

```text
AppCoordinator: exclusive speech reservation + quit preflight
  MeetingWindowController: native window + close save barrier
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
backups are preserved and fail closed. Manual file recovery remains necessary for corrupt meeting
metadata; the app does not silently restore an older record.

Records are limited to 8 MiB, titles to 4 KiB, notes and summaries to 1 MiB each, and transcripts
to 1,440 unique segments with validated offsets and sizes. Audio chunks are bounded binary
property lists containing 16 kHz mono Float PCM. Their filenames are unique chunk IDs. Completed
chunks are durable before transcription. The unfinished tail (about 20 seconds per source) can
be lost on process crash. A two-hour recording contains roughly 880 MiB of uncompressed audio
when both sources are continuously active; keep sufficient disk space available.

Notes autosave after a 600 ms pause. Close, navigation and audio removal pass through a save
barrier. A save failure retains the draft for retry or export. When idle, explicitly
confirming Discard Changes after a save failure restores the
last saved meeting without writing, hiding the error, or deleting captured audio. Export first
to keep unsaved edits; closing never discards automatically. Recover transcript retries saved
chunks; already persisted segment IDs are skipped. Remove saved audio requires every captured
chunk to have a durable transcript, and a user confirmation. It keeps notes, transcript and
summary. No automatic audio deletion or silent truncation occurs.

## Local summaries

Ollama must already be running with `qwen3:4b` installed (approximately 2.5 GB download).
Vani sends bounded transcript batches to `http://127.0.0.1:11434/api/generate`. It refuses redirects,
disables system proxies, caps each response at 256 KiB, checks completion and structured output,
and asks Ollama to unload the model afterward. There is no cloud fallback or configurable remote URL.

The model receives transcript data, not user-authored notes. Generated summary, decisions and
actions require a matching quote and timestamp from the transcript. Missing support or an
unavailable model produces an error and preserves the previous summary. User edits during
generation invalidate the result. Quoted evidence is a review aid, not proof against all model errors.
Long transcripts use bounded batches; output can be more verbose than a single consolidated summary.

## Validation boundaries

Tests cover native note editing, save/reopen, capture lifecycle, final-chunk transcription,
ASR retry, durable-audio deletion, failed stop/flush, stale callbacks, corrupt storage, private
permissions, invalid data and local summary fixtures. Review also covers the untouched dictation
regression suite. Hardware capture, long meetings, device changes, macOS permissions and VoiceOver
need actual-machine acceptance; unit fixtures are not evidence that a real call was captured.

There is no calendar integration, automatic meeting detection, pause/resume, person-level diarization,
or cross-meeting chat in this version. Those require measured designs rather than dormant abstractions.

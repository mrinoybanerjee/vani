# Changelog

All notable changes follow semantic versioning.

## 0.7.1 - 2026-09-23

### Fixed

- Dictation keeps recording when the default microphone changes or when the microphone in use
  is disconnected; it stays on the take's microphone while connected and resumes on the
  current input otherwise. Verified on hardware: default changed mid-take kept 5.2 of 5.0 s;
  microphone removed mid-take kept 4.8 of 5.0 s.
- Meetings recover when the microphone disappears (ScreenCaptureKit reports no error; a
  watchdog restarts capture after 2.5 s without microphone audio), keep recording Mac audio
  throughout, and say so if the microphone does not return. Verified on hardware: microphone
  removed at 3 s, recording resumed and continued to 12.8 s.
- Recovery restarts stop the stream they replace, cannot outlive a meeting, and a stream
  that fails to start can no longer silence the meeting.

### Accessibility

- VoiceOver no longer reads decorative icons; repeated buttons name their item; headings,
  selection and toggle states are exposed; announcements for recording, meetings, notes,
  saving and downloads never include note or transcript text. See
  [accessibility](docs/ACCESSIBILITY.md).
- Command-1, Command-2 and Command-3 open Meetings, Notes and Settings.

### Validation

- Two-hour meeting soak, a 30-minute real-speech meeting with Parakeet Unified (1.74% and
  1.55% WER), and summaries of 30-minute and two-hour transcripts within the model context.
  See [long meetings](docs/BENCHMARKS.md#long-meetings--september-23-2026).
- Opt-in real-hardware tests for microphone switches and meeting capture.

## 0.7.0 - 2026-09-23

### Changed

- NVIDIA Parakeet Unified EN 0.6B is the default speech model: 6–14% fewer word errors
  on single utterances than Parakeet TDT v2 in the LibriSpeech benchmark, with comparable
  capitalization and punctuation. See [speech accuracy](docs/BENCHMARKS.md#speech-accuracy).
- New installations download the verified 583 MiB model during setup. Existing
  installations keep dictating with the previous model and can switch from the menu;
  dictation keeps working during the download and the previous model remains the
  fallback if the new one cannot load. Meetings use the same model.

## 0.6.0 - 2026-09-23

### Added

- Double-tap the hold shortcut for hands-free dictation; press it again to insert. The
  overlay and menu show the locked state, with Stop and Cancel in the menu.
- Press Escape to discard a recording without inserting text. Typing a key chord while
  holding the shortcut (for example Fn-Delete) also discards it.
- Choose the Last Transcript chord: Control-Command, Option-Command, Control-Option or off.
- Smart Formatting: say "scratch that" (or "delete that"), set off by a pause or
  punctuation, to remove the sentence or clause you just said.
- Guided first-run setup in the menu with explicit status for each permission, the
  one-time model download and the Fn / Globe keyboard setting; a clear recovery when
  the shortcut is not active.
- Meetings: your dictionary and learned vocabulary apply to meeting transcripts;
  microphone lines that repeat Mac audio (no headphones) are marked as echo and hidden;
  "Me" and "Others" labels; Recently Deleted; Copy as Markdown; exports named after the
  meeting; summaries use your notes to decide emphasis and run in the background.

### Changed

- FluidAudio 0.15.8: long dictations make 8–23% fewer word errors on LibriSpeech
  long-form sets; short dictation accuracy is unchanged. See
  [speech accuracy](docs/BENCHMARKS.md#speech-accuracy).
- Meeting audio is cut at the quietest moment between 15 and 24 seconds instead of at
  exactly 20 seconds, so words are no longer split between chunks.
- Consecutive dictations are separated by a space; transcripts on the clipboard are
  marked transient and are not synced to other devices.
- The optional vocabulary model stays warm and is verified once, removing reloads after
  the shortcut is released; faster verification and clipboard restoration after paste.

### Fixed

- A shortcut release could be dropped behind another operation, leaving the microphone
  open until the 20-minute limit.
- Quiet speech in long dictations or meetings could be rejected as silence.
- Clips shorter than 0.3 seconds failed transcription with a Retry that could not succeed.
- One unknown or malformed setting reset the whole dictionary and snippets.
- A copied password (concealed clipboard content) was written back after dictation,
  defeating the password manager's auto-clear.
- "Period" and "colon" used as nouns became punctuation with Smart Formatting.
- Paste Last and a new recording could clear each other's transcript.
- The menu could report Ready while the shortcut was not listening.
- One untranscribable meeting chunk blocked recovery, summaries and audio removal;
  a single unsupported summary quote discarded the whole summary.
- Launch at login now reflects the login-item state in System Settings.

### For contributors

- `scripts/test.sh` requires Swift Testing's completion summary and runs each native
  window test in its own process. AppKit's nested run loops could stop the Swift async
  main loop and exit the test process with status 0 mid-run, silently skipping tests.
- A reproducible word-error-rate harness lives in `Benchmarks/`.

## 0.5.0 - 2026-09-13

### Changed

- Open Meetings, Notes and Settings in [one resizable native window](docs/WORKSPACE_DESIGN.md), with a shared sidebar and contextual libraries.
- Preserve editor and settings drafts across sections; save before navigation, and reveal failed saves when closing.
- Keep active meeting status visible while using Notes or Settings, and retain the same window on reopen.
- Route menu-bar actions and Command-comma into the workspace; replace custom meeting tabs with a native keyboard-accessible picker.

### For contributors

- Remove the separate notebook and meeting window controllers and standalone Settings scene. Audio, inference and persistence engines are unchanged.

## 0.4.1 - 2026-09-12

### Fixed

- Preserve unfinished dictionary entries when switching vocabulary sections.
- Preserve saved corrections when profile reads or quarantine operations fail, and retain the latest confirmed capitalization.
- Stop the microphone before publishing interrupted-dictation feedback.
- Reject malformed Accessibility ranges and preserve the transcript clipboard after an interrupted paste dispatch.
- Make summary cancellation effective during preflight and offer explicit discard after a failed meeting save.
- Let uninstall wait for graceful shutdown and abort safely when Vani is still running.

### Changed

- Remove promotional UI copy and the unused status-mark implementation.
- Append meeting audio in place instead of repeatedly copying the accumulated buffer.
- Validate every shell script during lint and correctly identify ad-hoc signatures during installation.

## 0.4.0 - 2026-09-12

- [Record a meeting](README.md#meeting-notes) with microphone and Mac audio, follow its incremental transcript, keep personal notes, recover saved audio and generate source-quoted summaries through local Ollama.
- Keep dictation and meeting recording from overlapping, retain drafts after failed saves, and prevent delayed capture events from interrupting a newer meeting.
- Redesign dictation, Notes, Settings, Teach and recording feedback with a unified native visual system.
- Add notebook focus mode, note previews, keyboard creation/search and safe category switching.

### For contributors

- Keep notebook presentation, draft coordination and window lifecycle separate while preserving the existing speech and storage engines.

## 0.3.0 - 2026-09-12

### Added

- [Vani Notes](README.md#run-locally): save a dictation or start a blank note, edit and search locally, export
  plain text, and recover notes from Recently Deleted.
- Recover a previous saved notebook copy when the current file cannot be read;
  private atomic storage preserves the unreadable file during explicit recovery.

### Fixed

- Prevent repeated stop and audio-route events from finalizing the same dictation twice.
- Preserve global learned corrections when teaching the same correction in another app.
- Keep an unfinished correction visible after a failed save and support Command-S.

### Changed

- Simplified menu and settings labels, empty states, and native editor spacing.
- Keep note storage separate from recording, insertion, models, and transcript history.

## 0.2.1 - 2026-08-28

### Changed

- Keep the Teach Vani editor visible and preserve an unfinished correction when Teach is
  selected again
- Let the correction window expand for larger accessibility text and wrapped content

### Fixed

- Make the Teach Vani correction field accept keyboard input and restore focus whenever
  Vani becomes active
- Keep the Teach UI automation fixture isolated from the real learned-corrections profile
- Prevent repeated Save clicks from counting one correction more than once
- Make timing-sensitive session coverage deterministic under parallel test execution

## 0.2.0 - 2026-08-16

### Added

- Add opt-in **Teach Vani** correction learning with a transparent local profile,
  per-entry deletion, and full reset
- Add optional experimental acoustic vocabulary boosting through a pinned Parakeet CTC
  110M model after a term is confirmed twice
- Add correction-diff, profile-storage, concurrency, model-integrity, false-positive,
  Debug privacy-gate, and real Release-model integration coverage
- Add Left Control as a hold-to-dictate shortcut option
- Add short, locally generated start and stop recording sounds with a Settings toggle

### Changed

- Store learned corrections in a versioned, bounded, private, atomic Application
  Support file rather than transcript history or preferences
- Bound model downloads during transfer before verifying exact size and SHA-256 content

### Fixed

- Keep optional vocabulary failures from breaking a successful base transcription
- Disable FluidAudio acoustic rescoring in Debug builds, where version 0.15.5 enables
  transcript-bearing dependency logs
- Cancel a delayed cue-backed recording start when the hold key is released
- Let Command-Control Last Transcript chords take precedence over the Left Control hold key
- Prevent learned corrections from composing and expanding a snippet trigger

## 0.1.4 - 2026-07-31

### Changed

- Add a copy-paste update path and explain how free stable local signing keeps macOS
  privacy permissions attached across source rebuilds
- Document a targeted, non-destructive recovery flow for stale Vani permission records
  after an ad-hoc update
- Make setup-doctor and installer warnings explain the permission impact of ad-hoc
  signing and link directly to prevention and recovery instructions

### Fixed

- Treat `next line` and `next paragraph` as Smart Formatting aliases for the existing
  `new line` and `new paragraph` structural commands
- Preserve structural newlines when a command is spoken alone or at the beginning or
  end of a dictation

## 0.1.3 - 2026-07-30

### Changed

- Support memory-only dictations up to 20 minutes with a one-minute warning and
  automatic transcription at the limit
- Reserve long-recording capacity in bounded pages away from the real-time audio
  callback

### Fixed

- Preserve and transcribe captured speech when the recording buffer reaches its limit
  instead of discarding the usable audio
- Retain captured audio before duration validation so an unexpected over-limit result
  can be retried without recording again
- Keep raw captured audio available when final sample-rate conversion fails, and retry
  conversion without recording again
- Preserve pending recovery audio across inactive microphone route and sleep events
- Stop and retain active audio when sleep, permission, or microphone-route events
  interrupt a recording, so the captured portion can be transcribed after retry
- Reject input devices configured above 48 kHz before recording to keep the 20-minute
  memory bound predictable

## 0.1.2 - 2026-07-30

### Changed

- Use a native phase-aware waveform in the menu bar and the Vani speech-bubble
  mark in the status popover
- Keep stored transcript history clearable after history capture is disabled or a
  corrupt file is quarantined
- Normalize and bound dictionary entries, and reject duplicate or conflicting phrases
- Finish active capture cleanup before Vani quits
- Enforce warning-free Swift compilation in CI and release builds
- Move dictation feedback below the upper-right menu-bar area so it does not cover
  bottom-edge text fields
- Include Vani's license and third-party notices in built app bundles
- Update pinned GitHub Actions and CodeQL actions together

### Fixed

- Keep the Vani menu-bar status item visible in light and dark menu bars
- Preserve rapid shortcut releases that arrive while microphone capture is starting
- Preserve held-key state when macOS reactivates Vani
- Keep waveform animation dimensions stable to avoid unnecessary panel relayout
- Recheck secure fields and clipboard ownership at the exact paste-delivery boundary
- Require an exact value edit before treating selection-free insertion as verified
- Prevent stale session or history updates from overwriting newer UI state
- Stop late transcription and insertion work from mutating a disabled session
- Wait for an existing Vani process to exit before replacing the installed app
- Exclude release compilation time from reliability benchmark timing

## 0.1.1 - 2026-07-22

### Fixed

- Make AVAudioConverter input ownership explicit and concurrency-safe under Swift 6.3
- Exercise real 48 kHz to 16 kHz audio conversion in the regression suite

## 0.1.0 - 2026-07-22

### Added

- Native Swift 6 menu-bar app for Apple Silicon macOS
- Hold-to-dictate English transcription with FluidAudio and Parakeet TDT v2
- Pinned speech-model manifest with per-file SHA-256 integrity verification
- Verified Accessibility insertion and guarded clipboard fallback
- Transcript recovery, optional history, dictionary, diagnostics, and settings
- Deterministic fixture, 500-cycle reliability harness, CI, and release automation
- Public-repository Swift CodeQL scanning and Dependabot security updates
- Stable local signing support so macOS privacy grants survive normal rebuilds
- Exact-revision, exact-path model downloader with verified atomic installation
- Setup doctor, focused troubleshooting, and complete local uninstall guidance
- Memory-only Last Transcript copy and paste controls
- Local voice-triggered snippets with bounded exact expansion
- Opt-in deterministic Smart Formatting for spoken punctuation, fillers, and structure
- Secure-field detection that blocks recording and insertion in password fields

### Fixed

- Stop the hidden overlay animation so the warm menu-bar app returns to 0% idle CPU
- Capture Left Fn on key-down and release, including separate Input Monitoring setup
- Recover automatically from silence and verify delayed rich-text insertion
- Surface content-free diagnostics for settings, history, and hotkey startup failures
- Preserve the previous installed bundle until a verified replacement is ready
- Separate the fast user install path from the contributor test workflow
- Use private installer staging paths and remove ephemeral CI signing material
- Create the build staging directory during a direct clean-clone installation
- Report local and release signing identities correctly under shell pipe-failure checks
- Cancel superseded CodeQL runs to avoid wasting macOS CI capacity
- Use the fastest sufficient single-architecture debug build for Swift CodeQL
- Deliver paste events to the captured app even when its text field cannot be inspected,
  tolerate delayed rich-text updates, and preserve the transcript when verification is uncertain
- Protect links, email addresses, snippet text, Unicode casing, and mixed-case names during
  Smart Formatting

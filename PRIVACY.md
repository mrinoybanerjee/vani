# Privacy Contract

Vani is local-first by design.

## Privacy promises

- Microphone audio is processed on the Mac and is not uploaded.
- Dictation audio is not persisted. Explicit meeting recording saves audio locally for recovery.
- Transcript history is disabled by default.
- No account, analytics, advertising, or crash-reporting SDK is included.
- Dictation network access is limited to explicit model downloads. Meeting summaries send text only
  to Ollama at `127.0.0.1:11434`; redirects and system proxies are disabled. There is no cloud fallback.
- Support diagnostics exclude audio and transcript text by default.
- Snippets and optional Smart Formatting run entirely inside the Vani process.
- Opt-in learned corrections stay in a separate local profile and contain no audio.
- Quick notes persist through notebook actions. Meeting notes autosave after editing. Neither uploads text or audio.

The one-time model download comes from exact revision `4252711f6f060f9a2f91e5f081a806d7f45eebd8` of the
`FluidInference/parakeet-unified-en-0.6b-coreml` Hugging Face repository (about 583 MiB). Vani downloads only its 13 allowlisted
files and verifies each file before installation. Installations that already have the
previous `FluidInference/parakeet-tdt-0.6b-v2-coreml` model keep using it until the user
chooses to download the new one. After setup, dictation does not need a network connection.

If the user explicitly enables experimental acoustic vocabulary, Vani downloads the
optional Parakeet CTC 110M model from exact revision
`accdafd8cf8a2ff1cabe3c11e54416b405d409aa`. Its 12 allowlisted files are size-checked
during transfer and SHA-256 verified before atomic installation. Dictation still works
without this model and falls back to the base transcript if rescoring fails.

## Local storage

- Settings, dictionary entries, and snippet text are stored in the app's local
  preferences.
- Confirmed learned corrections are stored in
  `~/Library/Application Support/Vani/personalization.json`. The file is bounded,
  private, atomic, clearable, and quarantined if unreadable.
- The latest failed transcript or audio stays in memory until retry, success,
  discard, or app exit.
- Audio retained after sleep, permission loss, or a microphone-route interruption
  follows the same memory-only recovery lifecycle.
- The latest recognized transcript stays in memory for copy or paste until it is
  replaced or the app exits.
- Transcript history is written only when the user enables it. History is bounded,
  stored atomically, and can be cleared in Settings.
- Saved notes use plaintext JSON in `~/Library/Application Support/Vani/Notes`,
  protected by owner-only directory/file permissions, without app-level encryption.
  Notes are separate from history; clearing history does not delete them.
- Notes in Recently Deleted remain recoverable with no automatic purge. A previous
  saved copy and files preserved during explicit recovery can also contain note text.
  Export creates a plain-text copy at the user's chosen location; Vani does not
  manage that copy afterward. [Uninstalling](docs/UNINSTALLING.md) removes the local notebook.
- Diagnostics form a bounded in-memory ring of event codes, phases, timing, and
  counts. They do not include transcript, audio, clipboard, or focused-field data.

Any future feature that weakens these promises requires an explicit design review,
clear UI disclosure, and opt-in behavior.

## Meeting recording and summaries

Choosing **Meetings → Start a meeting** records the microphone and other Mac audio after
a disclosure and macOS permission approval. Let participants know before recording.
The system-audio source includes other applications and notifications, not just the meeting app.
Headphones reduce duplicate speech from microphone echo. ScreenCaptureKit supplies audio;
Vani registers no video output and saves no screen frames. Closing the meeting window
does not stop recording; the menu shows an active meeting and provides a route back to Stop.

Audio chunks, transcript, personal notes, summary and a previous saved record live in
`~/Library/Application Support/Vani/Meetings/<meeting-id>/`. Directories are owner-only
and files are owner-readable/writable. They are not encrypted by Vani. Completed audio
chunks are retained until **Remove saved audio** succeeds after transcript persistence.
There is no automatic purge. Up to about 24 seconds per source remain in memory before a
chunk is saved; a process crash can lose that unfinished tail. Capture stops at two hours.

Summaries use the local `qwen3:4b` model through an independently installed Ollama service.
Installing that model downloads approximately 2.5 GB; meeting content is not part of that download.
Vani sends transcript text and that meeting's own notes (bounded, as untrusted guidance on what
matters) only to the loopback service, never audio, and requests model unload after generation.
It also asks the same loopback service which models are installed, to show a setup hint. Ollama and any software running as the same macOS user remain trust
boundaries. Source quotes help review a summary; they do not prove that every generated
interpretation is correct. Dictation remains deterministic and does not use this model.

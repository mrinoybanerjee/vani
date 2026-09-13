# Privacy Contract

Vani is local-first by design.

## V1 promises

- Microphone audio is processed on the Mac and is not uploaded.
- Audio is not persisted by default.
- Transcript history is disabled by default.
- No account, analytics, advertising, or crash-reporting SDK is included.
- Runtime network access is limited to the explicit model download.
- Support diagnostics exclude audio and transcript text by default.
- Snippets and optional Smart Formatting run entirely inside the Vani process.
- Opt-in learned corrections stay in a separate local profile and contain no audio.
- Notes persist only through explicit notebook actions and never upload text or audio.

The one-time model download comes from an exact revision of the
`FluidInference/parakeet-tdt-0.6b-v2-coreml` Hugging Face repository. Vani downloads
only its allowlisted model files and verifies each file before installation. After
setup, dictation does not need a network connection.

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

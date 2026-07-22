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

The one-time model download comes from an exact revision of the
`FluidInference/parakeet-tdt-0.6b-v2-coreml` Hugging Face repository. Vani downloads
only its allowlisted model files and verifies each file before installation. After
setup, dictation does not need a network connection.

## Local storage

- Settings, dictionary entries, and snippet text are stored in the app's local
  preferences.
- The latest failed transcript or audio stays in memory until retry, success,
  discard, or app exit.
- The latest recognized transcript stays in memory for copy or paste until it is
  replaced or the app exits.
- Transcript history is written only when the user enables it. History is bounded,
  stored atomically, and can be cleared in Settings.
- Diagnostics form a bounded in-memory ring of event codes, phases, timing, and
  counts. They do not include transcript, audio, clipboard, or focused-field data.

Any future feature that weakens these promises requires an explicit design review,
clear UI disclosure, and opt-in behavior.

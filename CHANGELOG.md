# Changelog

All notable changes follow semantic versioning.

## Unreleased

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

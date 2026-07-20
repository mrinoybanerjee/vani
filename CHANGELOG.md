# Changelog

All notable changes follow semantic versioning.

## Unreleased

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

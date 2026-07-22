# Security Model

## Protected data

Vani handles microphone audio, transcript text, focused application identity, and
temporary clipboard content. Transcript and audio content are prohibited from logs
and diagnostics.

## Trust boundaries

- FluidAudio and its exact-pinned Swift dependencies execute in the Vani process.
- The English Core ML model is downloaded only after a user action from an exact
  repository revision and an allowlist of exact relative paths.
- Every required model artifact is checked against a byte count and SHA-256 digest
  pinned to an audited repository revision before Core ML loads it.
- Apple Accessibility and Core Graphics APIs can target other applications only
  after explicit macOS approval.
- Vani is not sandboxed because global key monitoring and cross-application text
  insertion are core product behavior.

## Controls

- Hold-to-record means no background microphone capture while idle.
- Global key-down events are filtered to the exact Last Transcript chords before
  they reach the main actor; key content is not retained or logged.
- Capture storage is preallocated and limited to two minutes.
- Process focus is checked before insertion, after paste delivery, and during bounded
  verification polling.
- Clipboard restoration is conditional on both insertion verification and an
  unchanged pasteboard change count.
- Recovery preserves content when success cannot be proven.
- Last Transcript content is memory-only and is never added to history a second time
  when pasted again.
- Snippet matching uses escaped literal triggers and one-pass expansion, preventing
  regex injection and recursive expansion.
- History is opt-in, bounded, atomic, and clearable.
- Diagnostics are content-free and bounded.
- Unexpected, missing, changed, hidden, or symlinked model artifacts are rejected.
- Model files are downloaded to a private staging directory, verified in full, and
  installed with same-volume renames; dynamic remote paths never reach the filesystem.
- CI uses exact action commit SHAs and exact Swift package versions.
- CodeQL analyzes Swift pull requests, main, and a weekly schedule when the
  repository is public.

## Known limitations

- Accessibility APIs are powerful by design. Install only builds from this repository
  or signed releases whose checksum you verify.
- Some controls do not expose readable Accessibility values. Vani still delivers one
  process-bound paste, leaves the transcript available for manual paste, and does not
  claim verified success.
- Ad-hoc local builds do not provide the identity or Gatekeeper assurance of a
  Developer ID signed, notarized release.
- The app has no automatic updater in v1.

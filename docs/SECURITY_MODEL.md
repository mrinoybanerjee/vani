# Security Model

## Protected data

Vani handles microphone audio, transcript text, focused application identity, and
temporary clipboard content. Transcript and audio content are prohibited from logs
and diagnostics.

## Trust boundaries

- FluidAudio and its exact-pinned Swift dependencies execute in the Vani process.
- The English Core ML model is downloaded only after a user action.
- Every required model artifact is checked against a byte count and SHA-256 digest
  pinned to an audited repository revision before Core ML loads it.
- Apple Accessibility and Core Graphics APIs can target other applications only
  after explicit macOS approval.
- Vani is not sandboxed because global key monitoring and cross-application text
  insertion are core product behavior.

## Controls

- Hold-to-record means no background microphone capture while idle.
- Capture storage is preallocated and limited to two minutes.
- Focus is checked before insertion and after paste delay.
- Clipboard restoration is conditional on both insertion verification and an
  unchanged pasteboard change count.
- Recovery preserves content when success cannot be proven.
- History is opt-in, bounded, atomic, and clearable.
- Diagnostics are content-free and bounded.
- Unexpected, missing, changed, hidden, or symlinked model artifacts are rejected.
- CI uses exact action commit SHAs and exact Swift package versions.

## Known limitations

- Accessibility APIs are powerful by design. Install only builds from this repository
  or signed releases whose checksum you verify.
- Some controls do not expose readable Accessibility values. Vani leaves the
  transcript available for manual paste instead of claiming success.
- Ad-hoc local builds do not provide the identity or Gatekeeper assurance of a
  Developer ID signed, notarized release.
- The app has no automatic updater in v1.

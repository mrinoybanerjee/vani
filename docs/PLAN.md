# SottoKey V1 Implementation Plan

Status: Proposed
Owner: mrinoybanerjee
Target: Apple Silicon macOS, English

## Outcome

Ship a signed, testable menu-bar app that captures speech through a hold shortcut,
transcribes English locally, inserts text into the focused app, and never loses the
latest transcript when insertion fails.

## Premises

1. Mac-only and English-only are deliberate quality constraints for v1.
2. Native Swift is the simplest and fastest architecture around Apple audio,
   Accessibility, and Core ML APIs.
3. Batch transcription after release is the default. Streaming is added only if
   measured release-to-insert latency misses the target.
4. Deterministic cleanup is safer and easier to test than generative rewriting.
5. Release engineering, privacy, and failure recovery are part of MVP quality.

These premises were approved in the 2026-07-18 gstack office-hours design.

## What already exists

- FluidAudio provides Apple Silicon speech models and Swift APIs.
- Apple provides AVAudioEngine, Core ML, Accessibility, Core Graphics, SwiftUI,
  AppKit, and ServiceManagement.
- The public LocalFlow project demonstrated one possible orchestration approach and
  passed 201 isolated tests, but SottoKey will not fork its implementation.
- Handy, VoiceInk, OpenWhispr, and Voquill establish that local dictation demand and
  open-source distribution already exist.

## Architecture

Use one Swift package graph:

```text
SottoKeyApp (@MainActor)
    |
    v
DictationSession state machine
    |----> AudioCapture actor ----> AVAudioEngine
    |----> SpeechEngine actor ----> FluidAudio/Core ML
    |----> TextPipeline ----------> deterministic rules + dictionary
    |----> TextInsertion ---------> Accessibility, then paste fallback
    `----> TranscriptRecovery ----> memory, optional local history
```

Initial targets:

- `SottoKeyCore`: state machine, audio, ASR adapter, text, insertion, storage
- `SottoKey`: AppKit/SwiftUI executable and resources
- `SottoKeyCoreTests`: unit, fixture, integration, and performance tests

Do not split these into more packages until build time or ownership boundaries prove
the split is useful.

## State model

```text
setup -> preparing -> ready -> listening -> transcribing -> inserting -> ready
                       |          |             |             |
                       `----------+-------------+-----------> recoverableError
```

Every event is accepted or rejected by the current state. Repeated key events,
permission changes, microphone route changes, sleep/wake, app termination, and model
failure have explicit transitions.

## Milestone 1: Repository and test harness

- Swift 6 package with strict concurrency checking
- CI build, unit tests, formatting check, and dependency review
- State machine with exhaustive transition tests
- Audio fixture loader and benchmark result schema
- App bundle assembly script for development

Exit: CI passes from a clean clone and produces a launchable unsigned development app.

## Milestone 2: Measured vertical slice

- Microphone permission and audio capture
- Configurable hold shortcut with duplicate-event protection
- FluidAudio English model lifecycle and batch transcription
- Conservative text cleanup
- Clipboard paste insertion with transcript recovery
- Minimal non-activating state overlay

Exit: fixed English fixtures transcribe and text reaches common focused fields without
network access after model setup.

## Milestone 3: Reliability and insertion

- Direct Accessibility insertion where supported
- Verified fallback behavior and clipboard restoration
- Silence, short-tap, clipping, and hallucination guards based on fixtures
- Sleep/wake, audio route change, permission revocation, and model failure recovery
- Optional bounded local transcript history, disabled by default

Exit: no transcript loss across the failure registry and 500 sequential test dictations
without unbounded memory growth.

## Milestone 4: Product finish

- Permission checklist, menu-bar popover, overlay, settings, and history UI
- Personal dictionary with exact correction and supported model biasing
- VoiceOver, keyboard navigation, contrast, Reduce Motion, and multi-display QA
- Resource, latency, and accuracy benchmark publication

Exit: design review and dogfood findings are resolved with no critical accessibility
or interaction defects.

## Milestone 5: Public release

- Developer ID signing, hardened runtime, notarization, checksums, and attestation
- Privacy validation and dependency/security review
- README, architecture, contribution, build, benchmark, and release documentation
- Private beta, then public GitHub repository and Homebrew Cask submission

Exit: a new user can install, grant permissions, download the model, and complete a
dictation without terminal commands.

## Performance gates

- Hotkey press to active capture: p95 below 75 ms
- Release to inserted text for 5 to 30 second utterances: p50 below 200 ms and p95
  below 500 ms on the baseline Apple Silicon Mac
- Idle CPU near zero while ready
- No unbounded memory growth across 500 sequential dictations
- Benchmark output records hardware, OS, model, corpus, build mode, and commit

If batch transcription misses the release latency gate, profile first. Streaming is
permitted only when measurements identify inference finalization as the bottleneck.

## Test diagram

| Flow or branch | Coverage |
| --- | --- |
| Valid hold, speech, release, insert | State, fixture, and integration tests |
| Duplicate press or release | State transition tests |
| Silence and short tap | Audio fixture tests |
| Permission denied or revoked | State and manual UI tests |
| Model missing, loading, corrupt, or failed | Adapter and recovery tests |
| Focus changes during dictation | Integration tests |
| Accessibility insert supported or rejected | Strategy tests |
| Paste succeeds, times out, or target changes | Integration and recovery tests |
| Sleep/wake and microphone route change | Integration tests |
| History disabled, enabled, full, or corrupt | Storage tests |
| 500 sequential dictations | Performance and leak test |

## Failure registry

| Failure | User-visible recovery | Critical gap before release |
| --- | --- | --- |
| No microphone permission | Open the exact System Settings pane | Yes |
| No Accessibility permission | Keep transcript and explain manual paste | Yes |
| Empty audio capture | Return to ready with a retry message | Yes |
| Model unavailable or corrupt | Repair or redownload with progress | Yes |
| Transcription failure | Keep audio only in memory until retry or discard | Yes |
| Insertion cannot be verified | Keep transcript in memory and clipboard | Yes |
| Clipboard changes during insertion | Do not overwrite newer user content | Yes |
| Target app closes or focus changes | Abort insertion and preserve transcript | Yes |
| Sleep or input route change | Rebuild capture before the next session | Yes |
| Local history corrupt | Quarantine history and continue without it | No |

## Not in scope

See [../TODOS.md](../TODOS.md). In particular, v1 has no cloud service, account,
generative rewrite, plugin system, meeting workflow, or non-Mac platform.

## Implementation rules

- Prefer standard Apple APIs over dependencies.
- Pin FluidAudio to an exact reviewed version.
- Keep real-time audio work allocation-bounded and lock-minimal.
- Never log audio or transcript contents.
- Do not restore the clipboard until insertion success is verified.
- Store settings with typed Codable structures and atomic writes where UserDefaults
  is not sufficient.
- Add no abstraction without a second implementation, a test seam, or a measured
  complexity reduction.

## Release blockers

- Final benchmark-selected English model
- Apple Developer ID credentials
- Security contact or GitHub private vulnerability reporting enabled
- Public name collision and trademark screen repeated before visibility changes

## Decision audit trail

| # | Decision | Classification | Rationale |
| --- | --- | --- | --- |
| 1 | Apple Silicon macOS and English only | User-approved scope | Focus quality and dogfooding |
| 2 | Native Swift modular monolith | User-approved architecture | Apple APIs dominate the hot path |
| 3 | Batch before streaming | Engineering default | Simplest design; benchmark can overturn it |
| 4 | Local deterministic cleanup | Product and privacy default | Predictable output without hidden rewriting |
| 5 | Public release only after private beta | Release default | Validate reliability before broad distribution |

# Engineering Instructions

## Product boundary

SottoKey v1 is an Apple Silicon, English-only, local dictation app. Do not add
cloud transcription, accounts, telemetry, plugins, meeting capture, or a generic
LLM cleanup layer without an approved design change.

## Workflow

Use the installed gstack workflow for substantive work:

- Product shaping: `office-hours`
- Plan review: `autoplan`, `plan-eng-review`, or `plan-design-review`
- Debugging: `investigate`
- Browser or interaction QA: `qa` or `qa-only`
- Code review: `review`
- Shipping: `ship`
- Repository memory: `setup-gbrain` and `sync-gbrain`

Run `sync-gbrain` after meaningful architecture or milestone changes.

## Engineering rules

- Prefer native Swift 6, AppKit, SwiftUI, AVFoundation, Accessibility, and Core ML.
- Keep one small Swift package graph. Add protocols only at external or test boundaries.
- Keep the audio callback real-time safe: no logs, model work, networking, or unbounded allocation.
- Model dictation as explicit state transitions and test every transition.
- Treat transcript recovery as a correctness requirement.
- Use deterministic text cleanup in v1. Do not silently rewrite meaning.
- Measure before adding streaming, caches, FFI, or concurrency complexity.
- Preserve user changes and do not use destructive git commands.

## Quality gates

- Swift concurrency checking enabled
- Unit and fixture tests for changed behavior
- Performance measurements for hot paths
- Accessibility and failure-state review for UI changes
- Security review before release

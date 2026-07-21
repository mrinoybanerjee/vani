<!-- /autoplan restore point: /Users/mrinoy/.gstack/projects/vani/main-autoplan-restore-20260717-205034.md -->
# Vani V1 Implementation Plan

Status: Implemented; public release credentials and dogfood percentiles remain open
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
  passed 201 isolated tests, but Vani will not fork its implementation.
- Handy, VoiceInk, OpenWhispr, and Voquill establish that local dictation demand and
  open-source distribution already exist.

## Architecture

Use one Swift package graph:

```text
VaniApp (@MainActor)
    |
    v
DictationSession state machine
    |----> AudioCapture actor ----> AVAudioEngine
    |----> SpeechEngine actor ----> FluidAudio/Core ML
    |----> TextPipeline ----------> deterministic rules + dictionary
    |----> TextInsertion ---------> target-bound paste + Accessibility verification
    `----> TranscriptRecovery ----> memory, optional local history
```

Initial targets:

- `VaniCore`: state machine, audio, ASR adapter, text, insertion, storage
- `Vani`: AppKit/SwiftUI executable and resources
- `VaniCoreTests`: unit, fixture, integration, and performance tests

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
- Safe paste insertion with transcript recovery
- Minimal non-activating state overlay

Exit: fixed English fixtures transcribe and text reaches common focused fields without
network access after model setup.

## Milestone 3: Reliability and insertion

- Target-bound paste insertion with observable verification
- Verified fallback behavior and clipboard restoration
- Silence, short-tap, clipping, and hallucination guards based on fixtures
- Sleep/wake, audio route change, permission revocation, and model failure recovery
- Optional bounded local transcript history, disabled by default

Exit: no transcript loss across the failure registry and 500 sequential test dictations
without unbounded memory growth.

## Milestone 4: Product finish

- Permission checklist, menu-bar popover, overlay, settings, and history UI
- Personal dictionary with deterministic exact correction
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
  below 500 ms on the documented baseline Mac. The first baseline is an Apple M4
  with 16 GB RAM; wider compatibility results are reported separately.
- Idle CPU near zero while ready
- Warm-model resident memory measured and published separately from idle CPU
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
| Accessibility observation available or unavailable | Strategy tests |
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
- Paste may restore the clipboard only after an observable target change is verified.
  Otherwise leave the transcript on the clipboard and report that insertion was not
  confirmed.
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

## GStack Autoplan Review

Review mode: selective expansion. UI scope: yes. Open-source developer experience
scope: yes. Outside voices were unavailable: Claude CLI had no authentication and
an isolated Codex reviewer exited before producing output. The review below is a
single-reviewer result and is labeled accordingly.

### CEO Review

#### Premise challenge

- **Right problem:** Confirmed. The narrow problem is trustworthy, local text entry,
  not broad voice productivity or feature parity with a cloud suite.
- **Do-nothing cost:** The user continues choosing between built-in dictation quality
  and cloud privacy tradeoffs. This is real dogfood pain, but public demand must still
  be validated after the first usable build.
- **Existing leverage:** FluidAudio and Apple frameworks remove the need to build an
  ASR model, audio stack, UI toolkit, or operating-system integration layer.
- **Distribution:** GitHub Releases plus Homebrew Cask is required. Source code alone
  is not a usable Mac product.

#### Dream state

```text
CURRENT                     V1                         12-MONTH IDEAL
Cloud or clumsy dictation -> local native voice key -> trusted open voice-input layer
Manual recovery           -> transcript never lost -> app-aware styles and languages
Unverified claims         -> public benchmarks     -> community benchmark corpus
```

#### Alternatives rechecked

| Approach | Effort | Risk | Decision |
| --- | --- | --- | --- |
| Native Swift modular monolith | Medium | Low to medium | Selected |
| Swift shell with Rust core | Large | Medium to high | Rejected until profiling proves an FFI-sized hot path |
| LocalFlow fork | Small initially | Medium long-term | Rejected to preserve clean ownership and differentiation |

#### Scope and temporal interrogation

- **Hour 1:** repository contract, state model, and build skeleton.
- **Hours 2 to 6:** exhaustive state tests before real microphone or model work.
- **First week:** one measured vertical slice, not settings breadth.
- **First month:** reliability, dogfood fixes, design finish, and a private beta.
- **Six-month risk:** adding cloud cleanup and cross-platform code before local
  insertion is excellent would erase the product's reason to exist.

#### Section findings

1. **Architecture:** The target graph is appropriately small. Model download,
   app-bundle assembly, and signing must be explicit modules in release work.
2. **Error and rescue:** Recovery ownership is now explicit. The latest transcript
   remains in memory until the next successful insertion or explicit discard.
3. **Security:** Direct distribution will use hardened runtime but not App Sandbox,
   because global event handling and cross-application insertion require broader
   system integration. This must be documented plainly.
4. **Data flow:** Focus and clipboard races are release-critical. The app may not
   claim paste success where the target value cannot be observed.
5. **Code quality:** Actor and protocol boundaries are sufficient. More targets or a
   dependency-injection framework would be unnecessary.
6. **Tests:** The test plan now distinguishes pure state tests, deterministic audio
   fixtures, live integration tests, and manual permission checks.
7. **Performance:** Batch transcription remains the default. Warm-model RAM and idle
   CPU are reported as separate metrics.
8. **Debuggability:** Add a bounded metadata-only diagnostic event ring. Transcript
   and audio contents are never logged.
9. **Deployment:** Signing credentials are a known release blocker. Development
   builds remain explicitly unsupported for sensitive work.
10. **Long-term trajectory:** Engine, cloud, and plugin abstractions remain deferred.
11. **Design and UX:** The compact system-native direction is sound; interaction
   coverage needs implementation screenshots before public claims.

#### Error and rescue registry

| Error | Detection | Rescue | User trust requirement |
| --- | --- | --- | --- |
| Permission denied | Authorization status | Exact Settings action | No raw system error |
| Empty capture | Sample count and energy | Return ready, retry | Never invent text |
| Model failure | Typed engine error | Repair or redownload | Preserve current transcript state |
| Focus changed | Target identity mismatch | Abort insertion | Never type into the wrong app |
| Event posting rejected | Core Graphics preflight failure | Manual paste recovery | Preserve transcript |
| Paste unobservable | Target has no readable value | Leave transcript on clipboard | Never report false success |
| Clipboard race | Change count mismatch | Keep newer user clipboard | Never overwrite user content |
| Sleep or route change | Workspace/audio notification | Rebuild before next session | Clear ready state until healthy |

### Design Review

The initial wireframe is a workflow artifact, not final visual design. The plan avoids
marketing composition, nested cards, custom control imitations, and decorative motion.

| Dimension | Score | Review result |
| --- | ---: | --- |
| Information architecture | 8/10 | One popover, setup checklist, and compact settings window are enough |
| Interaction states | 7/10 | Listening, processing, recovery, disabled, and permission states are specified |
| Journey and emotional arc | 8/10 | Setup explains trust, normal use disappears, failures stay actionable |
| AI-slop resistance | 9/10 | Native controls and materials; no gradients, oversized type, or decorative cards |
| Design-system alignment | 8/10 | System typography, semantic colors, 8-point rhythm, small corner radii |
| Accessibility and display behavior | 7/10 | VoiceOver, Reduce Motion, keyboard, contrast, and multi-display QA are required |
| Unresolved visual decisions | 7/10 | Brand icon and final accent await real screenshots, not speculative mockups |

**Overall: 7.7/10 before implementation.** The implementation target is 9/10 after
real screenshots, accessibility inspection, and dogfood review.

Design decisions:

- Default shortcut is Left Fn, with a small preset list rather than arbitrary
  shortcut composition in the first slice.
- Overlay appears on the active display, centered 24 points above the safe bottom
  edge, and never activates or intercepts clicks.
- Listening uses a low-cost five-bar meter. Processing uses an indeterminate native
  progress treatment. Success is a brief confirmation only when success is known.
- Errors remain until dismissed or recovered and contain one clear action.
- Persistent history is off by default. Settings must not imply that history is
  required for transcript recovery.
- Final visuals use system backgrounds and labels, one cool accent for active state,
  and semantic warning/error colors. The palette is not a single-hue theme.

### Engineering Review

#### Dependency graph

```text
Vani executable
  -> AppCoordinator (@MainActor)
      -> DictationSession actor
          -> AudioCapturing protocol -> AVAudioEngineAudioCapture
          -> SpeechRecognizing protocol -> FluidAudioSpeechEngine
          -> TextProcessing value pipeline
          -> TextInserting protocol -> SafePasteInsertion
          -> TranscriptRecovery actor
      -> OverlayController (non-activating NSPanel)
      -> SettingsStore
```

The executable depends on the core library. The core library does not import the app
target. UI observes immutable session snapshots rather than reaching into capture or
model objects.

#### Code quality constraints

- Swift 6 strict concurrency from the first commit.
- Typed errors and events; no stringly typed state transitions.
- No service locator, reflection-based dependency injection, or generic plugin registry.
- Production adapters are injected only where tests need deterministic substitutes.
- Audio callback work is bounded and does not await actors.

#### Test diagram

```text
State transition table --------> exhaustive unit tests
Text cleanup + dictionary -----> table-driven unit tests
WAVE fixture capture ----------> silence/noise/speech fixture tests
FluidAudio adapter ------------> fixed local model integration tests
Safe paste --------------------> fake adapter tests + pasteboard races + live app matrix
Sleep/route/permission events --> deterministic state tests + manual OS checks
500-session run ---------------> release performance/leak suite
```

The detailed test artifact is stored in the gstack project directory. No UI snapshot
test substitutes for live Accessibility and focus testing.

#### Performance review

- Keep the ASR model warm after setup to target release latency; measure its resident
  memory rather than hiding it inside an idle metric.
- Do not run repeated full-audio draft passes while the user speaks.
- Use signposts around capture start, release, inference, insertion, and recovery.
- Avoid disk I/O in the dictation path except explicit history persistence after a
  completed session.
- Profile before adding streaming, ring-buffer complexity beyond capture needs, or
  alternative engines.

#### Security and release review

- Pin FluidAudio exactly and review transitive dependencies.
- Verify model files against a release-controlled checksum manifest before loading.
- Do not accept arbitrary model URLs in v1.
- Do not log Accessibility values, selected text, clipboard text, or transcript text.
- Document the unsandboxed direct-distribution security boundary.
- CI never receives Developer ID credentials on pull requests from forks.

### Developer Experience Review

#### Contributor persona

Primary contributor: a Swift developer on an Apple Silicon Mac with current Xcode who
wants to improve local dictation, audio reliability, Accessibility integration, or UI.
They should not need FluidAudio internals knowledge to run unit tests.

#### Empathy narrative

"I found Vani through GitHub. Before I trust an app with microphone and
Accessibility permissions, I want to understand the privacy boundary in two minutes.
I expect one documented build command, tests that do not download a large model by
default, and errors that tell me whether I am missing Xcode, permissions, or model
assets."

#### Developer journey

| Stage | Target experience | Planned proof |
| --- | --- | --- |
| Discover | README states supported Mac and privacy boundary | README review |
| Evaluate | Architecture, privacy, security, and benchmark docs are findable | Link check |
| Clone | Standard Git clone, no submodules | Clean-clone CI |
| Build | One script or documented Swift command | CI and BUILDING.md |
| Test | Unit tests run without microphone or model download | Test job |
| Launch | Development app bundle assembled and opened | Smoke script |
| Change | Folder ownership and state model are obvious | ARCHITECTURE.md |
| Debug | Typed errors plus metadata-only diagnostics | Failure tests |
| Contribute | Small PR template and focused contribution guide | Contributor review |

#### DX scorecard

| Dimension | Current | V1 target |
| --- | ---: | ---: |
| Getting started | 4/10 | 9/10 |
| API and naming | 7/10 | 9/10 |
| Error and debugging experience | 5/10 | 9/10 |
| Documentation | 6/10 | 9/10 |
| Upgrade safety | 3/10 | 7/10 |
| Development tooling | 4/10 | 9/10 |
| Community readiness | 3/10 | 8/10 |
| Measurement loop | 5/10 | 9/10 |

Targets:

- Clone to unit tests: under 5 minutes with Xcode already installed.
- Clone to launchable development app: under 10 minutes, excluding first model download.
- A failed setup command states the problem, likely cause, and exact next action.
- Model-backed tests are opt-in and clearly labeled.

### Cross-phase themes

1. Reliability claims must be observable. Unknown insertion success is not success.
2. Privacy is structural: no cloud path, no content logs, no history by default.
3. Performance choices are benchmark reversals, not permanent abstractions.
4. Native visual quality comes from state coverage and restraint, not UI volume.
5. Public trust depends on install, build, test, release, and vulnerability workflows.

### Reviewed implementation tasks

- [x] **P1: Establish Swift package and exhaustive session state tests.**
- [x] **P1: Implement bounded audio capture and the local English ASR adapter.**
- [x] **P1: Implement transcript recovery and the honest insertion contract.**
- [x] **P1: Add benchmark schema, signposts, fixed fixtures, and baseline reports.**
- [x] **P2: Implement permission setup, menu bar, overlay, and compact settings.**
- [x] **P2: Add clean-clone CI, development app assembly, and contributor docs.**
- [x] **P2: Add security checks, model verification, and release workflow skeleton.**
- [x] **P3: Add optional local history and dictionary after the vertical slice is stable.**

### Autoplan decision audit trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | CEO | Keep the Mac/English wedge | Mechanical | Explicit over clever | Scope is already narrow and testable | Feature parity |
| 2 | CEO | Keep public distribution in MVP | Mechanical | Completeness | Uninstallable source is not a product | Source-only launch |
| 3 | Design | Use native restrained visual system | Mechanical | Explicit over clever | Lowest runtime and highest Mac consistency | Custom UI framework |
| 4 | Design | Keep errors visible and actionable | Mechanical | Completeness | Silent failure loses trust | Auto-dismissed errors |
| 5 | Eng | Treat unverifiable paste as recovery | Mechanical | Completeness | Avoid false success and data loss | Blind clipboard restore |
| 6 | Eng | Keep model warm but report memory | Mechanical | Pragmatic | Meets latency without hiding cost | Cold inference every use |
| 7 | Eng | Batch before streaming | Mechanical | Explicit over clever | Simpler until profiling says otherwise | Draft inference loop |
| 8 | DX | Separate unit and model-backed tests | Mechanical | Pragmatic | Fast contributor loop without hiding integration coverage | Mandatory model download |

## GSTACK REVIEW REPORT

### Review status

APPROVED_FOR_IMPLEMENTATION

### Scope

- CEO strategy review: complete
- UI design review: complete, 7.7/10 pre-implementation
- Engineering review: complete
- Developer experience review: complete
- Outside voices: unavailable; single-reviewer limitation recorded

### Blocking decisions

None. The final model selection and signing credentials are milestone gates, not
vertical-slice blockers.

### Required first proof

Implement the state machine and its exhaustive tests before integrating microphone,
model, insertion, or polished UI work.

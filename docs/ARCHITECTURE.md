# Architecture

Vani is a Swift 6 package with two production targets.

```text
Vani (SwiftUI/AppKit, @MainActor)
  -> DictationSession actor
     -> AVAudioEngineCapture actor
     -> FluidAudioSpeechRecognizer actor
     -> TextPipeline value type
     -> SystemTextInserter (@MainActor)
     -> TranscriptRecovery actor
     -> TranscriptHistoryStore actor
```

## State ownership

`DictationSession` is the only owner of the operational phase. Its explicit state
machine rejects duplicate and out-of-order events. UI receives immutable
`SessionSnapshot` values and cannot mutate the state directly.

The app moves through `setup`, `preparing`, `ready`, `listening`, `transcribing`,
`inserting`, and `recoverableError`. Permission loss, sleep, audio-route changes,
and termination have explicit transitions.

## Audio path

`AVAudioEngineCapture` installs one microphone tap. The tap copies samples into a
preallocated, duration-bounded ring buffer protected by `OSAllocatedUnfairLock`.
It does not log, allocate a growing collection, perform model work, or access the
network. Captured audio is converted to mono 16 kHz float samples after recording.

## Speech and text

`FluidAudioSpeechRecognizer` loads the English Parakeet TDT v2 Core ML pipeline and
uses CPU plus Neural Engine compute units. Vani downloads only an allowlist of exact
paths from a pinned model revision into private staging. Before atomic installation
and loading, it verifies the exact file set, sizes, and SHA-256 digests. `TextPipeline`
performs only conservative whitespace cleanup and user-defined exact phrase
replacement. V1 does not infer punctuation, style, intent, or surrounding context.

## Insertion contract

Vani records the focused process before capture and refuses insertion if the foreground
application changes. At insertion time it re-resolves that process's focused
Accessibility element, because dynamic web and rich-text controls can replace their AX
objects without changing the user's target. A readable element is verification evidence,
not a prerequisite for delivery.

Vani snapshots the pasteboard, writes the transcript, and sends one paced paste command
to the captured process. It polls app-scoped Accessibility state for up to two seconds
for an observable value, selection, range, or character-count change. It restores the
snapshot only after verification and only if another process did not change the
pasteboard. An unobservable paste leaves the transcript on the clipboard and presents a
neutral manual-paste hint; it is never reported as verified.

## Persistence

Settings are Codable values stored in `UserDefaults`. Optional history uses an
atomic local JSON file, is bounded, and quarantines corrupt data. Recovery audio and
the latest failed transcript are memory-only. Diagnostics are bounded and metadata
only.

## Dependency boundary

FluidAudio is the only external package. Its exact source revision and transitive
graph are locked by SwiftPM. Model artifacts are pinned independently by revision
and SHA-256 manifest. Apple frameworks provide audio, UI, Accessibility, global
keyboard events, login items, logging, and code signing integration.

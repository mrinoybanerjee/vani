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
uses CPU plus Neural Engine compute units. `TextPipeline` performs only conservative
whitespace cleanup and user-defined exact phrase replacement. V1 does not infer
punctuation, style, intent, or surrounding context.

## Insertion contract

Vani records the focused process before capture. It refuses insertion if the target
process changes. It first attempts a settable Accessibility selected-text operation
and verifies an observable value change. Otherwise it snapshots the pasteboard,
pastes, verifies the target value, and restores the snapshot only if the pasteboard
was not changed by another process. Unverifiable results remain recoverable.

## Persistence

Settings are Codable values stored in `UserDefaults`. Optional history uses an
atomic local JSON file, is bounded, and quarantines corrupt data. Recovery audio and
the latest failed transcript are memory-only. Diagnostics are bounded and metadata
only.

## Dependency boundary

FluidAudio is the only external package. Its exact source revision and transitive
graph are locked by SwiftPM. Apple frameworks provide audio, UI, Accessibility,
global keyboard events, login items, logging, and code signing integration.

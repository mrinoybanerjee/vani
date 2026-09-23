# Product Design

## Product

Vani is a native menu-bar dictation app for Apple Silicon Macs. Its v1 user is
someone who wants private English voice typing without an account or cloud service.

## Core workflow

1. Complete Microphone, Accessibility, and Input Monitoring permission setup.
2. Hold a global shortcut.
3. Speak while a non-activating overlay shows capture state.
4. Release the shortcut.
5. Transcribe locally and insert text into the focused application.
   Double-tapping the shortcut locks recording hands-free until the next press;
   Escape, the menu's Cancel, or typing a key chord while holding discards the take.
6. If insertion cannot be verified, keep the transcript on the clipboard and return to
   ready without blocking the next recording.

## Experience direction

- Warm native visual system defined in [DESIGN.md](../DESIGN.md), with adaptive light/dark paper surfaces and restrained green accents
- Compact menu-bar popover, one shared [Meetings, Notes and Settings workspace](WORKSPACE_DESIGN.md),
  and a focused correction window shown only when the user chooses Teach
- Optional Notes uses the shared sidebar and a spacious editor with search, title/text previews,
  keyboard creation/find/save, export, and Recently Deleted.
  Category changes save first; persistence status and save failures remain visible.
- Non-activating upper-right overlay with listening, processing, success, and error
  states, positioned below the menu bar so it does not cover common text composers
- No decorative motion; the only animation is the recording pulse, which stops under Reduce Motion
- No onboarding carousel, dashboard, document editor inside the dictation popover,
  decorative cards, or hidden background work

## Meetings

The user-approved all-local meeting workspace has a searchable library and three separate
views: My notes, Transcript and Summary. Recording starts only after an explicit disclosure.
The microphone and Mac audio are captured together; dictation pauses while meetings own
the shared speech recognizer. Stop finishes pending transcription before summary generation.
Failures retain source material and provide a retry. See [MEETINGS_DESIGN.md](MEETINGS_DESIGN.md).

## Reliability baseline

- A transiently unreadable Accessibility element must not block process-bound paste
  delivery.
- Slow rich-text fields receive a bounded verification window without automatic retries.
- Verified delivery restores the user's previous clipboard only while Vani still owns it.
- Unobservable delivery preserves the transcript and gives a truthful manual-paste hint.
- A changed foreground application aborts delivery so Vani cannot type into the wrong app.

## Product success

The app feels invisible when it works and explicit when it cannot. It is faster to
understand than built-in dictation, easier to trust than a cloud product, and
reliable enough that a user does not check whether every sentence survived.

The full presentation redesign and competitor research are recorded in
[REDESIGN_2026-09-12.md](REDESIGN_2026-09-12.md).

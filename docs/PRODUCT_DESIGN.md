# Product Design

## Product

Vani is a native menu-bar dictation app for Apple Silicon Macs. Its v1 user is
someone who wants private English voice typing without an account or cloud service.

## Core workflow

1. Complete microphone and Accessibility permission setup.
2. Hold a global shortcut.
3. Speak while a non-activating overlay shows capture state.
4. Release the shortcut.
5. Transcribe locally and insert text into the focused application.
6. If insertion cannot be verified, retain the transcript and offer manual paste.

## Experience direction

- Native system typography, materials, colors, controls, and accessibility behavior
- Compact menu-bar popover and one settings window
- Non-activating overlay with listening, processing, success, and error states
- Restrained 120 to 180 ms state transitions with Reduce Motion support
- No onboarding carousel, dashboard, editor, decorative cards, or hidden background work

## Product success

The app feels invisible when it works and explicit when it cannot. It is faster to
understand than built-in dictation, easier to trust than a cloud product, and
reliable enough that a user does not check whether every sentence survived.

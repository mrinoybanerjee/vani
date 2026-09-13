# Unified workspace

Meetings, Notes and Settings share one resizable native Vani window. The menu bar
remains the immediate dictation surface; its three destinations open or focus this
same window. Command-comma opens Settings there too. Teach Vani remains a focused,
transient correction editor because its explicit correction and keyboard-focus
contract is separate from workspace navigation.

## Layout and interaction

One 260 pt sidebar contains the wordmark, three navigation rows and the selected
section's library. The library changes in place; no second navigation rail appears.
Meetings and Notes use the remaining space for their editor and actions. Settings
uses a horizontal native picker for General, Vocabulary, Snippets, History and
Diagnostics. There are no new slogans, cards, animation or external UI dependencies.

The initial window is 1060 × 720 pt, resizable down to 820 × 560 pt. The sidebar is
resizable between 240 and 320 pt; the content area has a 560 pt minimum. Native
window frame autosaving remembers geometry. Existing warm paper, forest accent,
system controls and serif editor titles come from DESIGN.md. Light and dark mode
use the same hierarchy. Search, selected rows, field focus and selection are native
or explicitly labelled; selection is not indicated by color alone.

Switching sections saves the outgoing note or meeting draft before changing the
selection. A save failure leaves the draft and its recovery controls visible.
Switching does not stop a meeting. A compact, labelled meeting status remains in
the sidebar during capture, transcription, summarization or a meeting error.
Empty libraries identify their state and the main area provides the creation action.
Existing storage errors retain Retry, export and explicit discard paths.

All three content views retain their editor, tab and settings-draft state. Hidden
content is disabled, excluded from hit testing and hidden from accessibility so
keyboard shortcuts operate on the visible section. The feature models remain the
owners of files, drafts, audio and inference. Loading occurs only when requested;
retaining a view does not load speech models or start recording.

## Ownership and lifecycle

```text
AppCoordinator
  -> WorkspaceWindowController (one native window, activation and close callback)
     -> WorkspaceModel (selection and save barriers)
        -> NotesModel -> NoteStore actor
        -> MeetingModel -> existing audio, recognizer, summary and store boundaries
     -> WorkspaceView (navigation and retained feature views)
```

There is no generic router, navigation stack, service locator, event bus, model
migration or new package. Settings still bind to the existing AppCoordinator.
The old NotesWindowController, MeetingWindowController and standalone Settings
scene are removed. Sleep, permission interruption, speech reservation and quit
preflight reach the same MeetingModel through the workspace.

Closing saves both feature models, including hidden drafts; if either fails, the
workspace remains open and reveals that section. Closing during capture hides the
window while capture continues, as before. Reopening reuses the same window and
state. Quitting instead uses MeetingModel.prepareToQuit(), then saves Notes, before
terminating the dictation session. Navigation and close barriers reject overlapping
transitions and disable editing while a transition is being committed.

## Review and acceptance

The design review covered navigation hierarchy, empty/loading/failed/saving/recording
states, menu-to-workspace journeys, unnecessary copy and chrome, existing tokens,
compact sizing, keyboard focus and accessibility exposure. The user-selected
consolidation resolves the navigation choice; existing storage and recording
contracts govern lifecycle behavior. This change introduces no new audio behavior.

Acceptance checks cover repeated entry points using the same window, notes and
settings draft retention, failed saves blocking navigation and revealing hidden
drafts on close, fake recording continuing across navigation/close and stopping
once on quit, visible-section keyboard shortcuts, and native light/dark snapshots
at default and minimum size. Physical recording and full VoiceOver use are separate
hardware acceptance checks; native fixtures do not substitute for them.

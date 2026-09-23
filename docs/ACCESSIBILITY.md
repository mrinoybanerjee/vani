# Accessibility

Vani is designed to work with VoiceOver, keyboard-only use, Reduce Motion, Increase
Contrast and Differentiate Without Color. This page covers what is supported, how it
is tested, and what automated tests cannot prove.

## VoiceOver

- Every button, toggle, picker, text field and text area has a spoken name. Icon-only
  buttons are named by what they do, for example "Export note as text", "Meeting
  actions" and "Quit Vani".
- Buttons in repeated rows name their row, for example "Delete dictionary entry vani",
  "Edit snippet sign off" and "Delete learned correction vanny".
- The library filters ("All Notes", "Recently Deleted Meetings") have names that differ
  from the sidebar sections while still starting with the visible word, so VoiceOver
  and Voice Control users can tell them apart.
- Selected sidebar sections, filters, notes and meetings report selected state. Toggles
  report on/off. Tabs and settings sections are native segmented controls that report
  their selected segment.
- Page, menu and pane titles are headings, so the VoiceOver rotor can jump between them.
- Decorative symbols are hidden. Grouped text, such as setup steps, transcript lines and
  history rows, is read as one text element.
- Hidden workspace sections are not in the accessibility tree. The workspace keeps
  hidden pages alive at zero opacity, which removes them from the tree. It never applies
  `accessibilityHidden(false)` to the visible page, because that would expose the
  decorative symbols inside it under their raw symbol names.

### Announcements

Some state changes happen without moving focus, so Vani announces them. Announcements
name the state only. They never include transcript, note or meeting text.

| Surface | Announced |
| --- | --- |
| Dictation overlay | Listening; Hands-free recording locked; 1 minute remaining; Inserted; Paste sent, backup copied; failure title; Recording stopped (cancelled or ended without transcription) |
| Meetings | Meeting recording started / stopped (with the reason when interrupted); Summary ready; Summary not generated (with the error); meeting errors; moved to / restored from Recently Deleted; Copied meeting as Markdown |
| Notes | Note saved (explicit save); storage errors; moved to / restored from Recently Deleted |
| Settings | Settings errors (only while Settings is visible) |
| Teach Vani | Correction saved; Correction not saved |
| Downloads | Speech model and acoustic vocabulary downloads at 25, 50, 75 and 100 percent |

## Keyboard

Buttons, pickers and list rows are reachable with Tab when macOS Keyboard navigation is
on (System Settings > Keyboard). This is standard macOS behaviour. Text fields are
always reachable. Shortcuts:

| Where | Shortcut |
| --- | --- |
| App | Command-Comma opens Settings |
| Workspace | Command-1 Meetings, Command-2 Notes, Command-3 Settings |
| Meetings | Command-N new meeting (asks for recording consent first), Command-F search, Command-S save notes |
| Notes | Command-N new note, Command-F search, Command-S save |
| Dictionary | Return in either field adds the entry |
| Teach Vani | Command-S save, Escape cancel |
| Dictation | Hold key, double-tap for hands-free, Escape cancels (when enabled) |

Note and meeting actions (move to Recently Deleted, restore, recover transcript, remove
audio) are in the focusable actions menu button. Restore is also a visible button.
Settings list rows have visible Edit and Delete buttons in addition to context menus.

## Motion, contrast and colour

- Motion only signals recording. With Reduce Motion on, the overlay's recording dot
  stays still. The elapsed time and the "Listening" or "Hands-free" label still show
  that recording is in progress.
- State is never shown by colour alone. Selected notes and meetings have a leading
  accent bar and a heavier title. Selected sections and filters use a heavier weight.
  Recording, errors, echo lines and failed transcript parts are labelled in text.
- With Increase Contrast or Differentiate Without Color on, selected rows, sections and
  filters also get a visible accent outline. With Increase Contrast, the accent colour
  deepens and hairlines become clearly visible (see `VaniTheme`).

## How it is tested

`Tests/VaniAppTests/AccessibilityAuditTests.swift` (under `NativeInteractionTests`, one
process per test) hosts each surface in a real `NSWindow` or `NSPanel`. It then walks
the NSAccessibility hierarchy the way an assistive client does. SwiftUI builds its
tree only for an assistive client, so the test sets `AXEnhancedUserInterface` on its
own process; nothing system-wide changes. Surfaces covered:

- Menu: setup, ready (with Last Dictation and the model offer), model download,
  listening, hands-free, transcribing, error/recovery with a settings error, shortcut
  inactive, preparing, meeting in progress.
- Workspace: Meetings (empty; notes, transcript with echo and failed segments, summary;
  Recently Deleted; recording through a fake capture), Notes (editor, Recently Deleted,
  nothing selected, storage error), Settings inside the workspace.
- Settings: General, Vocabulary (dictionary entries), Learning (corrections, download
  progress), Snippets, History (empty and with entries), Diagnostics.
- Teach Vani (including a failed save) and the dictation overlay panel.

Every reachable element is checked for:

- a spoken name on interactive roles;
- a real label on text fields, not only a placeholder;
- no exposed images and no role-less labelled elements;
- no duplicate control names;
- on/off values on toggles.

Each surface also declares the headings, selected and unselected items, names and
values it must expose, plus the hidden-section controls that must be absent.
Announcements are captured through `VoiceOverAnnouncer.post`, and a test asserts that
they contain no note or meeting content. `AccessibilityAnnouncementTests` covers the
announcement and progress-milestone rules. A keyboard test drives Command-1/2/3,
Command-F and Command-N through `performKeyEquivalent`.

To read what VoiceOver would reach on each surface:

```bash
VANI_A11Y_REPORT_DIR=/path/to/reports swift test --filter AccessibilityAuditTests
```

`VANI_UI_SNAPSHOT_DIR` also renders a high-contrast workspace snapshot
(`captureHighContrastSelectionWhenRequested`) next to the existing light and dark
snapshots.

## Limits

- The automated tree audit is not a substitute for a VoiceOver user session. It
  checks names, roles, states and structure. It does not check reading order, rotor
  navigation, how natural announcements sound, focus after actions, or Voice Control.
  Before a release, check each surface with VoiceOver and with Keyboard navigation on.
- The tests cannot turn on Increase Contrast, Differentiate Without Color or Reduce
  Motion, because those are system settings. The high-contrast snapshot sets the
  appearance on the window only, which changes the colours but not SwiftUI's
  `colorSchemeContrast`. The selection outline therefore needs a manual check.
- Library rows are focusable buttons in a scroll view, not a native list, so the
  arrow keys do not move between rows; use Tab with Keyboard navigation on.
- Progress indicators expose a 0–1 value, which VoiceOver reads as a percentage.

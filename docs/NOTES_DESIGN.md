# Local Notes

Approved scope: the user's September 12 request to also build Vani Notes,
following phase 1 of COMPETITIVE_DISCOVERY.md.

One optional native window provides a searchable list, title and text editor,
Save (Command-S), new blank note, save-last-transcript, export, Recently Deleted,
and Restore. Notes are explicitly persisted independently of dictation history.
Closing or switching notes saves the current edit first; a failed save retains
the editor and prevents that transition. Save status stays visible. Unsaved
edits can be lost in a process crash; this first release does not claim autosave.

```
Menu action -> NotesWindowController -> NotesModel -> NoteStore actor
                   native UI            draft       atomic versioned JSON
DictationSession -> read last transcript only --------^
```

Keep capture, target-app insertion, shortcuts, learning and model ownership
unchanged. The store is created only on opening Notes. It uses an owner-only
directory, bounded reads/writes, validated version/IDs/content and a previous
saved copy. Corruption fails closed; explicit restoration preserves the unreadable
file. Soft deletion changes one field, with no irreversible deletion control.
There is no meeting capture, cloud service, summarizer or new dependency.

Tests cover durable create/edit/reopen, search, trash/restore, export formatting,
duplicate clicks, invalid/oversized files, recoverable corruption, permissions,
failed saves retaining drafts, switching and close guards, native text entry,
and repeat window presentation. Run the existing full dictation suite unchanged
and signed app checks before installing. Inspect native light/dark renders.

Architecture review: one store and one UI owner are sufficient. No generic
repository layer or background service. Code-quality review: errors are surfaced
at the window, draft text is never replaced after a failed write. Performance
review: storage runs on its own actor, only on explicit actions; notes are bounded
to 1,000 records and 16 MiB total, with no silent truncation. Test review: every
new persistence transition gets a real temporary-directory round trip; native
view tests cover the user-facing integration.

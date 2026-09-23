# Local Personalization

Status: Approved for implementation

## Outcome

Vani learns confirmed corrections on-device so repeated names, terminology, casing,
punctuation, and application-specific phrases improve over time without an account,
telemetry, retained audio, or model training.

## Product contract

- Learning is opt-in, visible, editable, and reversible.
- Vani learns only from a correction the user explicitly saves.
- Vani never treats its own transcript as ground truth.
- Correction data stays on the Mac and is stored separately from transcript history.
- Audio remains memory-only and is never added to the personalization profile.
- Personalization may improve a transcript but must never make dictation depend on the
  optional vocabulary model.

## Architecture

```text
Captured audio
    |
    v
Parakeet Unified (or TDT v2) -----------------+
    |                                         |
    |                                   active learned terms
    |                                         |
    +--> optional experimental CTC acoustic rescoring <----+
                |
                v
        learned deterministic corrections
                |
                v
      dictionary -> snippets -> Smart Formatting
                |
                v
         insertion and in-memory last transcript

Saved correction -> bounded diff -> local learned profile -> next dictation
```

`DictationSession` remains the operation owner. It chooses an application-scoped
`SpeechRecognitionContext`, asks the recognizer for a transcript, applies learned
corrections, and then runs the existing `TextPipeline`.

## Data model

Each learned correction contains:

- the phrase Vani produced;
- the user's replacement, which may be empty for an explicitly removed filler;
- the target application's bundle identifier when available;
- confirmation count and last-confirmed date;
- a stable identifier for editing and deletion.

The profile is a versioned atomic JSON file owned by an actor, bounded to 1 MiB and 200
corrections, protected with private directory/file permissions, and quarantined if it
is corrupt or unsafe. Phrases are normalized, duplicates merge, and manual dictionary
and snippet triggers take precedence. Conflicting replacements prefer the current app,
then a global rule, and are applied in one pass so learned rules cannot cascade. Active acoustic terms require two confirmations,
exclude removals and terms under four characters, and use conservative rescoring with
acoustic rescue disabled. Ranking is application match, confirmation count, recency,
then phrase length; at most 50 terms are supplied to acoustic rescoring.

## Correction flow

1. After a successful dictation, **Teach Vani** opens the in-memory last transcript in
   a focused correction window. Reopening Teach brings the same window forward without
   discarding an unfinished edit.
2. The user edits it and saves.
3. A bounded word diff extracts changed spans. Unchanged text is not stored.
4. Vani shows the learned corrections in Settings, where each can be deleted or all
   learning can be reset.

The correction editor teaches future dictations. It does not silently inspect or
rewrite text in another application.

## Acoustic vocabulary model

FluidAudio 0.15.8 exposes CTC keyword spotting and vocabulary rescoring. Its documented
batch convenience overload is not present in the pinned source, so Vani explicitly
runs TDT, retains token timings, tokenizes the active terms, runs CTC keyword spotting,
and performs constrained rescoring. Vani keeps
the current Parakeet TDT v2 base model and optionally loads the separate Parakeet CTC
110M model. The additional files are downloaded only from an exact revision, through
Vani's allowlist, size checks, SHA-256 verification, private staging, and atomic install.

The CTC repository is pinned at `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`
with an exact 12-file size and SHA-256 manifest. Vani never calls FluidAudio's mutable
model downloader. The model is downloaded only after an explicit user action. If it is missing, corrupt,
or fails during rescoring, Vani falls back to the base transcript and deterministic
learned corrections. Loaded CTC objects are released after an idle period.

FluidAudio 0.15.8 hard-enables transcript-bearing rescorer logs in Debug builds. Vani
therefore never invokes acoustic rescoring in Debug. Release builds compile those logs
out and exercise the real model through a separate opt-in integration test.

## Failure and rescue registry

| Failure | Behavior |
| --- | --- |
| Empty or unchanged correction | Save nothing |
| Oversized or adversarial correction | Reject or bound before diffing |
| Multiple edits | Learn each bounded changed span |
| Profile decode failure | Fall back to safe defaults |
| Profile full | Evict the lowest-ranked correction |
| Optional model absent | Continue with deterministic personalization |
| Optional model download/integrity failure | Keep the existing installation and show an error |
| CTC inference/rescoring failure | Use the unmodified TDT result |
| Short or ambiguous acoustic term | Exclude it from acoustic boosting |
| Manual dictionary conflict | Manual dictionary wins |

## Test plan

| Code path | Required coverage |
| --- | --- |
| Correction diff | insertion-only ignored; delete, replace, casing, punctuation, multiple spans, bounds |
| Profile normalization | invalid data, deduplication, merging, capacity, legacy decode |
| Active-term ranking | app match, confirmations, recency, manual override, 50-term cap |
| Text pipeline | learned correction ordering and empty replacement |
| Session integration | context passed to ASR, correction candidate retained, retry unchanged |
| Model integrity | exact manifest, tamper, symlink, unexpected file |
| Download | byte ceiling, retries, staging, rollback |
| Acoustic rescore | fixture comparison when the optional model is installed |
| Acoustic negative control | absent custom term must leave baseline output unchanged |
| Logging gate | Debug build cannot enter FluidAudio's transcript-bearing rescorer |
| UI | disabled, empty, learned, download, failure, delete, reset states |
| Regression | full debug and release tests, app build, lint, doctor |

## Not in scope

- Passive monitoring of edits in other applications
- Cloud profiles or synchronization
- Retaining correction audio
- Neural model fine-tuning
- Generative rewriting or synonym substitution
- Reading surrounding document contents

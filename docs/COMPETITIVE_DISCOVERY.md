# Vani competitive discovery and product direction

Research date: September 12, 2026. Status: design proposal, not implemented functionality.

## Recommendation

Make Vani exceptional at private English dictation on a Mac, then add an optional
Notes experience with its own lifecycle. Preserve the current shortcut, model,
text-insertion contract, recovery behavior, and default privacy settings throughout.
Competing on every platform, integration, and generative feature would work against
the requested simplicity and the user's already successful daily workflow.

The useful product lessons are Wispr Flow's low-friction voice input and vocabulary
personalization, and Granola's document-centered experience with inspectable source
evidence. The opportunity for Vani is a focused local product with explicit control
over capture, faithful text, durable notes when requested, and easy export. Better
accuracy, speed, or usability than either competitor remains a hypothesis requiring
comparative measurement.

## Scope and evidence

Reviewed official product pages, pricing, privacy/data controls, help workflows,
integrations, and release announcements. Inspected the public Wispr Notetaker and
Granola landing pages visually in a browser. These are marketing showcases, not
hands-on testing of either installed application. No competitor account was created,
no meeting was recorded, and no private Vani content was uploaded.

Vani's existing capabilities below come from the current repository's
[README](../README.md), [architecture](ARCHITECTURE.md),
[product design](PRODUCT_DESIGN.md), [privacy contract](../PRIVACY.md), and
[benchmark record](BENCHMARKS.md). They are not a fresh installed-app certification.
This document proposes future work; it does not modify the v1 boundary in
[AGENTS.md](../AGENTS.md).

Use current help pages to qualify landing-page claims. One Granola search snippet
still described desktop speakers as only Me/Them; opening the live page showed
new speaker-tag support. Wispr's site advertises its Notetaker broadly while a
September 11 help page still marks availability as limited. Pricing and rollout
gates can change; recheck before a purchase or a public comparison.

## Three products, different jobs

| User need | Wispr Flow Dictation | Wispr Flow Notetaker | Granola | Vani today |
| --- | --- | --- | --- | --- |
| Speak into an existing text field | Main product | Complements Dictation | Chat voice input is scoped to Granola | Main product |
| Turn speech into polished prose | Context-sensitive cleanup and formatting | Meeting summaries | Notes enhanced from meeting context | Optional conservative deterministic formatting |
| Personal names and terminology | Dictionary, learned corrections, snippets | Reuses dictionary and meeting context | Personal/workspace jargon | Dictionary, explicit Teach, optional acoustic vocabulary |
| Capture a meeting | Separate Notetaker | Microphone and system audio, no meeting bot | Microphone and system audio, no meeting bot | Not implemented |
| Notes, transcript, summary | Dictation history | Separate Thoughts, Transcript, Summary | Manual and enhanced notes with transcript inspection | Memory-only latest transcript; optional bounded history |
| Ask questions across meetings | Through Notetaker | Advertised with source links | Chat, templates/Recipes, shared context | Not implemented |
| Offline transcription | No; cloud transcription | Offline recording can defer cloud transcription | Provider-based transcription | Yes after model download |
| Platforms | Mac, Windows, iOS, Android | Mac; availability gates | Mac, Windows, iOS, Android; Apple Watch offering | Apple Silicon Mac, macOS 14+, English |

The matrix records documented presence, not comparative quality scores. Sources:
[Flow overview](https://docs.wisprflow.ai/articles/2772472373-what-is-flow),
[Notetaker editor](https://docs.wisprflow.ai/articles/9406970664-meeting-notes-and-the-editor-in-notetaker-beta),
[Granola Chat voice input](https://docs.granola.ai/help-center/getting-more-from-your-notes/granola-chat-dictation-vs-transcription),
[Granola transcription](https://docs.granola.ai/help-center/taking-notes/transcription),
and the detailed sources below.

### Wispr Flow Dictation

The core interaction is familiar to Vani: hold a shortcut, speak, release to insert.
Wispr layers in correction interpretation, per-app writing style, automatic dictionary
learning, snippets, and over 100 languages. Its benefit is reducing editing after
speaking while working inside the destination app. The homepage's four-times-faster
claim and testimonials are vendor claims, not controlled benchmarks.
[Product](https://wisprflow.ai/).

Hands-free operation can start from a shortcut, double-tap, or Flow Bar. Command Mode
is a paid experimental feature for spoken editing instructions; its help page
acknowledges that some failed edits show no error. These add convenience but increase
the consequences of ambiguous intent. Vani should first preserve predictable
transcription; any future rewriting needs explicit invocation and original-text
recovery. [Hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free),
[Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode).

Wispr's current desktop dictation limit is about six minutes according to its
overview. Vani documents a 20-minute bound. That is a useful difference in supported
duration, not evidence that Vani's long-form transcription is more accurate.
[Flow overview](https://docs.wisprflow.ai/articles/2772472373-what-is-flow).

### Wispr Flow Notetaker

Wispr announced Notetaker on August 5, 2026, and added Otter imports on September 4.
It combines live capture, a later transcript pass, speaker names informed by meeting
context, summaries, cross-meeting questions, briefs, and MCP access. Existing
dictation vocabulary carries into meetings: a meaningful product advantage for
people already using Flow. [Release notes](https://wisprflow.ai/whats-new).

The marketed experience includes a personal thoughts area, transcript and summary,
catch-up during a call, named action items, and source-linked answers. Calendar and
connected information help contextualize names. Those mechanisms plausibly improve
usefulness, but no independent accuracy test was performed here.
[Notetaker product](https://wisprflow.ai/notetaker).

Current help documents qualify availability as Mac and limited rollout. Recording
starts through an explicit action; the landing page's automatic-start wording should
not be read as unattended capture. Permission setup precedes recording, and each
calendar occurrence receives its own note to avoid duplicate sessions.
[Recording workflow](https://docs.wisprflow.ai/articles/9238501024-recording-a-meeting-with-notetaker-beta).

Dictating during a meeting temporarily hands the microphone to Dictation while
meeting system-audio capture continues. Wispr documents cases where the microphone
fails to resume and the user's speech is missing. It also supports recording offline
for later transcription. This is concrete evidence of the complexity introduced by
combining these workflows, not proof the implementation is generally unreliable.
[Concurrent dictation](https://docs.wisprflow.ai/articles/8175153619-dictating-during-a-meeting-with-notetaker-beta).

### Granola

Granola centers the meeting document: write a few useful notes while audio is
transcribed, then enrich those notes from the transcript and calendar. Generated
points can be traced to raw notes or transcript passages. Users can edit either
version, regenerate, and apply templates. This makes personal attention and
verifiability part of the workflow.
[Enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes).

Capture begins after opening a meeting note or explicitly creating a note. The
desktop implementation captures combined system audio, so unrelated playing audio
may be included. Back-to-back calls can merge when the meeting app keeps the mic
active; the docs recommend stopping between calls. Speaker tags now work for Google
Meet through an extension and for Zoom on Mac, with Me/Them fallback where tags are
unavailable. [Transcription](https://docs.granola.ai/help-center/taking-notes/transcription).

Granola extends the document into cross-meeting Chat, Recipes, shared folders and
team context. Its integrations catalog includes note destinations, CRMs, and AI
tools; Business pricing specifically lists Notion, Slack, HubSpot, Attio, Affinity,
Zapier, MCP, and API access. These are valuable for teams but would substantially
expand Vani's authorization, storage, and support obligations.
[Integrations](https://www.granola.ai/integrations),
[Plans](https://www.granola.ai/pricing).

Briefs prepare for external meetings using earlier notes, shared context, calendar,
web sources, and optionally Gmail. Current help limits them to Business/Enterprise
with Google Calendar; it does not guarantee a brief when useful context is missing.
That restraint is a good principle for Vani: an empty result is better than invented
context. [Briefs](https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs).

Granola's release history shows expansion from a notepad toward a team-context
product: MCP, APIs, Chat, briefs, Android, and Apple Watch. Its September language
announcement advertises 32 desktop languages. Platform support should be checked
separately; this is not a uniform capability promise across devices.
[Updates](https://www.granola.ai/updates),
[Language announcement](https://www.granola.ai/updates/granola-now-supports-32-languages).

## Privacy and commercial tradeoffs

| Product | Published price snapshot, USD | Processing and retention |
| --- | --- | --- |
| Wispr | Free desktop dictation: 2,000 words/week. Pro: $15/user/month monthly, or $12/user/month annual. Notetaker has plan-dependent weekly/history limits; the public comparison does not give precise meeting counts. | Dictation transcription always occurs in the cloud. Storage, training, and context settings are separate controls. Notetaker transcripts are stored in Wispr's cloud. |
| Granola | Basic free; Business $14/user/month; Enterprise $35/user/month as displayed. Homepage describes free access to the most recent 30 days. | Audio goes to transcription providers; notes/transcripts are cloud stored. Local note caching does not mean offline transcription. |
| Vani | Free open source, local build. | Local inference, no account/telemetry, history off by default, memory-only recovery audio. |

Sources: [Wispr pricing](https://wisprflow.ai/pricing),
[Wispr data controls](https://wisprflow.ai/data-controls),
[Granola pricing](https://www.granola.ai/pricing),
[Granola homepage](https://www.granola.ai/),
[Granola security](https://www.granola.ai/security),
[Vani privacy](../PRIVACY.md).

Wispr's August 18 data policy distinguishes disabling model improvement from disabling
cloud transcription. It also describes surrounding-field/app context and optional
broader context awareness. Third-party no-training promises do not mean data stays
on the device; some Notetaker features have different retention arrangements.
[Data controls](https://wisprflow.ai/data-controls).

Granola says third-party providers may not train on user data; Granola itself may
use anonymized data for improvement unless the user opts out, with Enterprise opted
out by default. Its security page describes US-hosted AWS storage and no retained
meeting recordings after transcription. These are vendor statements, not an audit
of provider systems. [Security](https://www.granola.ai/security),
[Training controls](https://docs.granola.ai/help-center/consent-security-privacy/model-training).

Avoid transferring broad security badges to every product feature. Wispr's current
pricing specifically says Notetaker is disabled on BAA accounts; its troubleshooting
documents the same restriction. [Pricing](https://wisprflow.ai/pricing),
[Notetaker restrictions](https://docs.wisprflow.ai/articles/3089221553-troubleshooting-notetaker-recording-and-audio-beta).

## Experience and visual direction for Vani

Observed in the public showcases: Wispr uses warm pale surfaces, prominent editorial
type, restrained purple actions, and clear product separation. Granola uses generous
white space, a green accent, and a large readable document as its central object.
Granola's own redesign account describes a deliberate pairing of display and UI
type. Borrow the clarity and hierarchy, not their brand, custom fonts, or marketing
animation. [Wispr showcase](https://wisprflow.ai/notetaker),
[Granola showcase](https://www.granola.ai/),
[Granola redesign](https://www.granola.ai/blog/a-new-look-for-granola).

For the current app, retain the native menu-bar surface and non-activating overlay.
Use system text styles, consistent spacing, one accent, semantic status colors,
and text labels alongside state icons. Keep the next useful action obvious in
permission, download, processing, recovery, and ready states. Settings should use
short labels and disclosure for rare options. Avoid a dashboard, usage streaks,
duplicated status cards, decorative gradients, and another onboarding sequence.

A future Notes window should look like a document: compact searchable note list,
title, content, small toolbar, and explicit capture status. Keep transcript
inspection available without requiring it to dominate the editor. Preserve manual
notes independently of any generated output. Label the recording source and show
Stop prominently; privacy must remain legible even when visual chrome is minimal.

Validate light/dark appearance, VoiceOver names and focus order, keyboard-only use,
Increase Contrast, Reduce Motion, narrow windows, long names, empty states, and
failure states. Cosmetic changes must not alter target-app activation or steal
focus during dictation.

## Proposed Notes architecture

The simplest useful first step is an explicit **Save last transcript as note**
action and a native local editor. That provides a trustworthy private voice notebook
using the current dictation engine before adding long meeting capture. It is not
Granola parity and should not be described as an AI meeting notetaker.

Suggested future ownership, within the existing small Swift package graph:

```text
AppCoordinator
  ├── DictationSession                 existing behavior and state machine
  └── NotesWindowController            opened only when requested
       └── NoteStore actor             versioned local note documents

Later, only when meeting capture is designed and validated:
NotesSession actor
  ├── capture                         mic + explicitly selected system audio
  ├── bounded transcription chunks    stable sequence and timestamp identities
  └── NoteStore                       manual notes + transcript segments

Optional later local summarizer
  └── derived summary + references to original transcript segments
```

Keep dictation history and saved notes separate: a note is explicitly persisted;
ordinary dictation still is not. Start with atomic, versioned local documents and
bounded reads, with recoverable deletion and export to Markdown/plain text. Use a
database only if measured note count, search latency, or transaction needs justify
it. Do not introduce a service layer, plugin framework, generic workflow engine,
vector store, or account system for a personal notebook.

Meeting capture needs a different lifecycle from hold-to-talk. Do not extend the
20-minute in-memory dictation buffer indefinitely. Use bounded chunks with one
ordered consumer and an explicit backlog ceiling; surface gaps, resource exhaustion,
and partial recovery truthfully. Durable audio chunks, if needed for crash recovery,
change the current privacy contract and require disclosed opt-in and cleanup rules.
If a session stays memory-only, disclose that an app crash loses uncommitted audio.

Initially permit only one capture mode at a time. A request for Dictation during
Notes capture should explain the conflict and offer a deliberate stop/switch,
never silently hand off the microphone. Reuse the recognizer boundary only after
resource ownership is clear; model work must never enter the real-time callback.
Any future simultaneous mode needs dedicated mic ownership and gap tests, not a
shared flag or incidental actor scheduling.

Meeting summaries are a separate optional, cancellable derived operation. Keep
source text immutable, preserve manual edits, label generated content, and store
source segment references for every factual bullet. Unsupported owners, dates,
numbers, decisions, and commitments must remain unknown. Do not feed generated
summaries back into transcription, corrections, or future truth. Load a local
summary model only on explicit use, if it meets measured memory/latency/quality
limits; a faithful transcript without a summary remains a complete saved result.

## Delivery phases and acceptance gates

These phases are proposed future work, not completed milestones or automatic
authorization to change capture and privacy behavior.

| Phase | Deliverable | Required evidence before moving on |
| --- | --- | --- |
| 0: Preserve and improve dictation | Bounded bug fixes and native UI refinement | Existing unit/fixture/recovery tests pass; hot-path before/after measurements; real target-app check; exact source/build record; installed working app retained until validation |
| 1: Private notebook | Save transcript, edit/title/search, reopen, export, recover deletion | Explicit persistence only; restart and corrupt-file recovery; no capture or clipboard side effects; offline workflow; keyboard/VoiceOver review; no changes to existing preferences |
| 2: Meeting capture | Opt-in Notes recording with explicit sources and Stop | Approved capture/retention design; supported OS/device matrix; 30/60/120-minute fixtures; route/sleep/permission/disk-full/crash cases; gap reporting and bounded memory; meeting/dictation ownership tests |
| 3: Helpful local summaries | Notes-guided summaries with source inspection | Representative consented/synthetic meeting corpus; unsupported-fact checks; source links resolve; cancellation/OOM fallback preserves source; no idle or default-dictation resource regression |
| 4: Broader capabilities | Only a demonstrated need, such as calendar or export automation | Specific permission and data-boundary design; bounded read/write behavior; independent provider readback for exports; existing offline path continues to work |

The current benchmark document leaves hotkey-to-capture p95 and
release-to-insertion percentiles unmeasured. Its deterministic 500-cycle harness
does not exercise real microphones, permission prompts, target apps, or daily
hardware changes. Existing fixture timing must not be presented as end-to-end
latency. Close these evidence gaps before adding runtime complexity.

For a fair comparison, use the same consented English utterances, Mac, microphone,
destination fields, and ground truth. Include short messages, long thoughts, names,
numbers, corrections, snippets, accent variation, silence, and noise. Measure:

- Word/error rate and meaning-changing errors separately from polish preferences.
- Editing effort to reach the intended final text, not speaking speed alone.
- Hotkey-to-capture and release-to-verified-insertion p50/p95/p99, warm and cold.
- Wrong-target paste, silent loss, duplicated insertion, and successful recovery.
- Idle CPU, steady/peak memory, model load, sustained capture, and energy impact.

Record model/build/OS/hardware versions and raw trial counts, and compare candidate
results against an unchanged baseline on the same machine. Any lost text,
wrong-target insertion, permission regression, or privacy-contract violation is a
release blocker. Investigate performance changes beyond measured run-to-run noise;
do not bury regressions in a single average or assert that finite testing proves
there are no bugs.

For summaries, evaluate both coverage and faithfulness: which important facts were
missed, which statements lack support, whether owners/dates are correct, and whether
every citation opens the right source. Include interruptions, unresolved decisions,
negation, conflicting dates, unnamed speakers, and long silence. A small fast local
model is useful only if it reduces work without fabricating commitments.

The immediate product decision is to finish the existing dictation audit and
validation, then pursue Phase 1 as a small separate change. Full meeting capture and
generative notes should be reviewed against this design before implementation.

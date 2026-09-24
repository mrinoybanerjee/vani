# Benchmarks

Performance claims are published only with hardware, OS, model, build mode, and
commit metadata. The first baseline machine is an Apple M4 Mac.

## Implemented gates

- A 500-cycle session harness covers capture, transcription adapter, cleanup,
  insertion, recovery cleanup, and bounded diagnostics with deterministic fakes.
- The bundled 16 kHz English fixture validates audio loading and enables an opt-in
  real-model test.
- Benchmark records use the versioned `BenchmarkResult` schema.
- Content-free Instruments intervals cover model preparation, transcription, and
  insertion.

Run the reliability harness and write local metadata to
`.build/benchmarks/latest.json`:

```bash
./scripts/benchmark.sh
```

Run the real model fixture after downloading the model:

```bash
VANI_RUN_MODEL_TESTS=1 swift test -c release \
  --filter bundledEnglishFixtureTranscribesLocally
```

Run the synthetic 20-minute model boundary separately:

```bash
VANI_RUN_LONG_MODEL_TESTS=1 swift test -c release \
  --filter twentyMinuteEnglishFixtureTranscribesLocally
```

Run the full paged capture and 48 kHz conversion boundary separately:

```bash
VANI_RUN_LONG_AUDIO_TESTS=1 swift test -c release \
  --filter twentyMinutePagedCaptureDrainsAndResamples
```

## Speech accuracy

Measured on 2026-09-23 on an Apple M4 (macOS 26.6.2) with the harness in
[Benchmarks/](../Benchmarks/README.md): Parakeet TDT v2, release build, CPU + Neural
Engine, 830 recordings and 9,694 seconds of audio from LibriSpeech test-clean and
test-other. Long-form items join consecutive utterances from one chapter (60–312 s).
Lower WER is better.

| Set | Items | FluidAudio 0.15.5 | FluidAudio 0.15.8 |
| --- | ---: | ---: | ---: |
| test-clean, single utterances | 400 | 2.22% | 2.22% |
| test-other, single utterances | 400 | 4.20% | 4.20% |
| test-clean, long-form | 15 | 3.33% | **2.57%** |
| test-other, long-form | 15 | 5.28% | **4.88%** |

Both versions ran at about 135× real time over the whole set. Vani ships 0.15.8: short
dictation is unchanged and long dictation loses 8–23% of its errors, consistent with
upstream fixes to chunk-seam merging and trailing-word recovery. The two residual
"catastrophic" test-other items are dialect spellings in the reference transcripts
("awk'ard", "all outer is own ead"), not recognition failures.

NVIDIA Parakeet Unified EN 0.6B (int8 encoder, same harness and FluidAudio 0.15.8):

| Set | Parakeet TDT v2 | Parakeet Unified |
| --- | ---: | ---: |
| test-clean, single utterances | 2.22% | **1.91%** |
| test-other, single utterances | 4.20% | **3.96%** |
| test-clean, long-form | 2.57% | **2.45%** |
| test-other, long-form | **4.88%** | 5.01% |

Unified ran at about 114× real time (v2: about 135×). It is the default from v0.7.0:
single utterances, which dominate dictation, lose 6–14% of their errors. Formatting is
comparable: 7.8% of Unified's single-utterance outputs start lowercase (v2: 9.9%), and
53.9% end without terminal punctuation (v2: 51.2%; LibriSpeech segments often end
mid-sentence). The pinned files at revision `4252711f` are byte-identical to the files
measured here. Inside Vani the 5.855-second fixture transcribed in 0.068 seconds.
Whole test-process peak resident memory for that short fixture was 632 MiB with Unified
(534 MiB with v2). The 20-minute model boundary processed in 7.6 seconds with 1.28 GiB
peak (v2: 3.8 seconds, 629 MiB), within the README's 1.5 GB guidance for the full limit. LibriSpeech is read audiobook speech; it does
not measure conversational dictation, accents, noise or domain vocabulary.

## Results

On 2026-09-23 (v0.6.0 candidate, FluidAudio 0.15.8, same M4, macOS 26.6.2), the
release-mode 20-minute boundary test transcribed 20 minutes of repeated fixture audio
in 3.818 seconds of test time with 660,013,056 bytes (629 MiB) peak resident memory for
the whole test process. The 20-minute paged capture and 48 kHz resampling boundary
passed in 0.324 seconds. Repeated audio is not a quality benchmark.

Local verification on 2026-07-19 used an Apple M4 running macOS 26.5.2. With the
model already downloaded, the release-mode integration test loaded the model and
transcribed a 5.855-second English fixture in 1.391 seconds of test wall time. This
validates faster-than-real-time engine execution for one fixture; it is not an
interactive latency percentile. Fifteen seconds after launching the installed app
with its model warm, CPU time remained unchanged over a 10-second observation and
`ps` reported 0.0% CPU with 531,296 KiB RSS.

On 2026-07-30, the committed release-mode 20-minute boundary test on the same M4
returned nonempty text in 10.882 seconds of test wall time, including model preparation.
A separate engine-focused run completed in 8.217 seconds with 1,005.8 MiB peak
test-process RSS. A 10-minute engine-focused run completed in 4.675 seconds with
840.3 MiB peak RSS. Repeated audio is not a quality benchmark; these runs validate
bounded long-input execution and inform the memory guidance.

The committed 20-minute paged capture test copied 48 kHz tap-sized buffers, preserved
the bounded prefix, and converted it to 16 kHz in 0.251 seconds of test time. A measured
`swift test --skip-build` invocation reported 861,995,008 bytes (about 822 MiB) maximum
RSS for the test command. This stress case excludes the speech model.

On 2026-08-16, seven repeated release runs of the 5.855-second fixture measured a
0.0797-second median engine duration at the pre-personalization commit and a
0.0793-second median with personalization disabled, an effectively unchanged default
path. Five optional acoustic-personalization runs measured 0.1768 seconds median with
a matching term and 0.1756 seconds without one. The `swift test` command peaked at
about 974 MiB for the base fixture and 1,282 MiB with the optional CTC model loaded;
these are test-process peaks, not installed-app RSS. The acoustic path remains
experimental because this single fixture validates execution and conservative fallback,
not an accuracy improvement across representative speakers and terms.

| Metric | Target | Current published result |
| --- | ---: | --- |
| Cached-model fixture | Faster than real time | 1.391 s for 5.855 s audio |
| Hotkey to capture p95 | < 75 ms | Pending instrumented dogfood run |
| Release to insertion p50 | < 200 ms | Pending instrumented dogfood run |
| Release to insertion p95 | < 500 ms | Pending instrumented dogfood run |
| Sequential reliability | 500 cycles | Passing in automated test |
| Idle CPU | Near zero | 0.0% over a 10 s release-build observation |
| Warm-model memory | Reported separately | 531,296 KiB RSS (about 519 MiB) |
| 20-minute model boundary | Completes locally | 10.882 s test wall; 1,005.8 MiB measured peak RSS |
| 20-minute capture boundary | Bounded and transcribable | 0.251 s test; about 822 MiB command RSS |

Unmeasured rows are release evidence gaps, not implied passes.

## Meeting append microbenchmark — September 12, 2026

On the M4 Mac with Swift 6.1.2 (`swiftc -O`), 20,000 alternating callbacks appended
320 float samples each across two source buffers, flushing every 320,000 samples.
Both variants retained exactly 6,400,000 samples. Three runs measured 0.178–0.253 s
for copy-out/append/write-back, versus 0.00121–0.00131 s for Dictionary's in-place
modifying subscript. This isolates avoidable Array copy-on-write; it excludes PCM
conversion, disk writes, capture, transcription and summaries. It is not a whole-app
speedup or a competitive benchmark. Functional tests separately verify persisted samples.

## Long meetings — September 23, 2026

Apple M4, 16 GB, macOS 26.6.2, Swift 6.1.2, release test builds at commit `2cfd066`
(v0.7.0 plus the summary fix below). Three opt-in tests, skipped by default:

```bash
# Two-hour soak: synthetic ScreenCaptureKit-shaped callbacks, fake recognizer (about 25 s)
VANI_RUN_LONG_MEETING_SOAK=1 swift test -c release --filter LongMeetingSoakTests
# 30-minute LibriSpeech meeting with the real Parakeet Unified model (about 80 s)
VANI_LIBRISPEECH_DIR=<path>/LibriSpeech/test-clean \
VANI_UNIFIED_MODEL_DIR="$HOME/Library/Application Support/Vani/Models/parakeet-unified-en-0.6b-int8" \
VANI_LONG_MEETING_OUTPUT=<folder> swift test -c release --filter thirtyMinuteMeeting
# Summaries at scale against local Ollama qwen3:4b (about 10 minutes)
VANI_RUN_MEETING_SUMMARY_SCALE=1 VANI_LONG_MEETING_RECORD=<folder>/librispeech-30min-meeting.json \
  swift test -c release --filter longTranscriptsStayWithinContext
```

**Method.** The tests drive the production `MeetingStreamOutput.append` (chunking, 16 kHz
conversion, atomic chunk files), `MeetingStore` and `MeetingModel` (drain, retry, echo
marking, saves) from a background thread standing in for ScreenCaptureKit's serial queue, while
the main actor transcribes concurrently. Callbacks carry 1,024 frames of Mac audio and 480
frames of microphone at 48 kHz with timestamp jitter. Nothing touches the microphone, screen
capture or TCC.

**Two-hour soak** (synthetic voiced signal: alternating turns of 2–45 s, 0.3–2 s pauses, a
20–90 s silence every 10–20 minutes, room noise on the microphone; one 3-second Mac-audio
delivery gap at 40:00 and 10 minutes at 44.1 kHz from 60:00):

| Metric | Result |
| --- | --- |
| Callbacks / chunks / segments | 1,055,076 / 858 / 858 (limit 1,440) |
| Longest chunk | 23.90 s (limit 25 s); 4 Mac-audio chunks under 15 s; the gap and both rate changes each end a chunk early |
| Audio covered | Mac 7,197.04 s of 7,197 s (gap excluded); microphone 7,200.000 s of 7,200 s |
| Worst join between consecutive chunks | 4.7 ms (timestamp jitter); offsets strictly increasing |
| Final record | 225,531 bytes (limit 8 MiB) |
| `store.save` p50/p95, first vs last 100 saves | 1.03/1.30 ms vs 2.65/2.93 ms (linear in record size) |
| Per-chunk drain cycle p50/p95, first vs last 100 | 17.4/30.4 ms vs 24.4/39.5 ms |
| Echo marking over the full transcript | 858 segments in 39 ms; 80 of 80 planted echo copies marked |
| Wall time / peak resident memory | 9.1 s (stop and final drain 0.6 s) / 90.1 MiB |

If Mac audio callbacks stopped during silence instead of carrying zeros (unverified for
ScreenCaptureKit), every pause over 0.5 s would end a chunk: 805 chunks for the conversation
above and 1,091 for a brisk one with 746 remote turns of 1–8 s. Both fit the 1,440 limit;
the margin shrinks with more, shorter turns.

**30-minute real speech.** Six LibriSpeech test-clean speakers (1089, 1188, 121, 1221 and 1284
as Mac audio; 1320 as the microphone), 95 turns of one to three utterances (180 utterances, 37
on the microphone), 0.25–0.6 s pauses inside turns and 0.3–2 s between, 30.2 minutes,
upsampled to 48 kHz and fed through the pipeline above to `FluidAudioSpeechRecognizer`
(Parakeet Unified). The baseline transcribes each whole turn alone from its 16 kHz source.
WER uses the normalization of `Benchmarks/wer.py`.

| Source | Pipeline WER | Isolated turns WER | Chunks (transcribed) | Chunk cuts inside an utterance |
| --- | ---: | ---: | ---: | ---: |
| Mac audio (3,567 words) | 1.74% | 1.51% | 113 (103) | 84 |
| Microphone (905 words) | 1.55% | 1.55% | 117 (30) | 17 |

The pipeline ran in 16.5 s for 30.2 minutes (about 110× real time) with 504 MiB peak process
memory. Mac audio has 8 more errors in 3,567 words (+0.22 points). Diffing both outputs shows
three duplicated words inside a chunk ("Saint George George", "Another Another", "This out This
outward") in 16.5–21.1 s chunks, and one word lost at a chunk start ("hussy"); the remaining
differences are spelling variants that both runs share or trade. FluidAudio's offline Unified
path decodes in fixed 15-second windows with a 2-second overlap merge, so every 15–24 s chunk
has one merge seam; the duplications are consistent with that seam, not with Vani's cuts, but
this run does not isolate the cause.

No-headphones run: the microphone also carries the Mac audio at −20 dB, delayed 30–120 ms per
utterance. 83 of 87 echo-only microphone chunks with at least 8 words were marked as echo; none
of the 30 chunks containing at least 0.5 s of the user's speech was hidden, and 98.78% of the
user's reference words remained visible (98.67% when transcribed alone). Four chunks that
overlap the user's turn only in the leading or trailing silence of a LibriSpeech file were
hidden correctly. Mac audio WER was unchanged at 1.74%.

**Summaries at scale** (qwen3:4b, 8,192-token context; token counts are Ollama's own
`prompt_eval_count`):

| Transcript | Batches | Largest prompt | Consolidation | Time | Quotes matched |
| --- | ---: | ---: | --- | ---: | ---: |
| LibriSpeech, 30 min, 24,396 characters | 3 | 3,084 tokens | Ran, 1,672 tokens | 144.5 s | 31 of 31 |
| Synthetic 2-hour product meeting, 108,977 characters | 10 | 3,065 tokens | Ran, 3,047 tokens | 452.2 s | 70 of 70 |

Every request stayed below 8,192 − 1,800 prompt tokens; the character-based estimate
(3 bytes per token) overestimates real English by about 45%, so consolidation of a two-hour
meeting fits with room to spare. Before the fix in this change, the two-hour consolidation
merged 33 different action items into one line ("Multiple people will draft customer notices
…"), which passed the new-facts check because every name and day appeared somewhere in the
cited items. Merged items now cite only items sharing at least two distinctive words; the
rerun kept 27 distinct actions. Output varies between runs even at temperature 0, and the
30-minute audiobook transcript yielded "decisions" and "actions" drawn from fiction, all
correctly quoted: quote validation proves provenance, not relevance.

**Limits.** Delivery is synthetic: no live ScreenCaptureKit session, device change, sleep,
Bluetooth route change or real acoustic echo was exercised, and whether ScreenCaptureKit
delivers silent Mac-audio buffers was not observed. The soak signal is tonal, not speech.
LibriSpeech is read speech with clean turn-taking and no overlapping talk; the echo is a
delayed, attenuated copy, not a room response. The synthetic two-hour summary transcript is
template text. Peak memory is for the whole test process, including test fixtures.

## Hardware checks — September 23, 2026

MacBook Air (M4), macOS 26.6.2, v0.7.1 candidate. A temporary signed helper app ran Vani's
production capture code with real devices: the built-in microphone, an iPhone Continuity
microphone, and a temporary aggregate input that was removed mid-recording. The helper used
the same triggers as Vani (engine configuration changes and default-input changes).

| Case | Result |
| --- | --- |
| Default input changed mid-dictation | Kept 5.2 of 5.0 s (stays on the take's microphone) |
| Recording microphone removed mid-dictation | Kept 4.8 of 5.0 s, resumed on the built-in microphone |
| 44.1 kHz input removed mid-dictation | Kept 5.0 of 5.0 s |
| Meeting microphone removed at 3 s, Mac audio playing | Mac audio uninterrupted; microphone resumed at 6.6 s and continued to 12.8 s; no failures |
| Mac audio captured and transcribed (Parakeet Unified) | The played clip was transcribed correctly both times |

Before the fixes, the same checks lost audio: switching to the iPhone microphone delivered
nothing for over 3 s (2.1 of 5.4 s kept); a default change silently stopped the engine tap
(2.0 of 5.0 s); a removed meeting microphone stopped delivering without any error (microphone
audio ended at 3.3 s). Limits: the aggregate input shares the built-in microphone's clock, so
a true sample-rate mismatch between two physical microphones was not exercised; Bluetooth
headsets, sleep during a meeting and multi-hour live calls were not tested on hardware.

## Speech cleanup — September 23, 2026

Smart Formatting's deletion-only cleanup (`SpeechTidier`) was chosen on DisfluencySpeech
real audio: Parakeet Unified transcribed each recording, Smart Formatting and then the
cleanup ran on the result, and word error is measured against the human fluent reference.
The rules were frozen before the fresh set was scored, once. Lower is better.

| Set | Items | Smart Formatting | With cleanup | Meant words removed | Negations lost | Words added |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| DisfluencySpeech held-out test | 250 | 11.0% | **7.4%** | 1.7 per 1k | 0 | 0 |
| DisfluencySpeech train sample, untouched | 250 | 12.2% | **8.1%** | 1.0 per 1k | 0 | — |

On LibriSpeech test-clean fluent read speech (300 utterances), the cleanup changed 0.3%
of utterances. The rules ran in about 0.6 ms p50 per utterance in the Python reference.
The Swift port matched that reference byte for byte on 1,825 inputs (Parakeet transcripts
after Smart Formatting, LibriSpeech and synthetic dictation cases) and measured 0.17–0.18 ms
p50 and 0.54–0.75 ms p99 per line over two release test builds on an Apple M4 (16 GB,
macOS 26.6.2, Swift 6.1.2). It now differs on 9 of them only by keeping the comma after an
opening word when it removes a filler ("So, um, what" becomes "So, what", not "So what").

Rejected alternatives: a local LLM (qwen3 1.7B) reached 11.2%, altered 5.7% of items,
added words in 2% and took about 1 s per utterance; a DistilBERT disfluency tagger reached
7.5% but removed 17.7 meant words per 1k, lost negations and was trained on
non-commercial data. These sets do not measure dictated lists or spoken commands.

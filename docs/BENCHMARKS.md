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

## Results

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

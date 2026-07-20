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

## Results

Local verification on 2026-07-19 used an Apple M4 running macOS 26.5.2. With the
model already downloaded, the release-mode integration test loaded the model and
transcribed a 5.855-second English fixture in 1.391 seconds of test wall time. This
validates faster-than-real-time engine execution for one fixture; it is not an
interactive latency percentile. Fifteen seconds after launching the installed app
with its model warm, CPU time remained unchanged over a 10-second observation and
`ps` reported 0.0% CPU with 531,296 KiB RSS.

| Metric | Target | Current published result |
| --- | ---: | --- |
| Cached-model fixture | Faster than real time | 1.391 s for 5.855 s audio |
| Hotkey to capture p95 | < 75 ms | Pending instrumented dogfood run |
| Release to insertion p50 | < 200 ms | Pending instrumented dogfood run |
| Release to insertion p95 | < 500 ms | Pending instrumented dogfood run |
| Sequential reliability | 500 cycles | Passing in automated test |
| Idle CPU | Near zero | 0.0% over a 10 s release-build observation |
| Warm-model memory | Reported separately | 531,296 KiB RSS (about 519 MiB) |

Unmeasured rows are release evidence gaps, not implied passes.

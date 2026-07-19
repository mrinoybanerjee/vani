# Benchmarks

Performance claims are published only with hardware, OS, model, build mode, and
commit metadata. The first baseline machine is an Apple M4 Mac.

## Implemented gates

- A 500-cycle session harness covers capture, transcription adapter, cleanup,
  insertion, recovery cleanup, and bounded diagnostics with deterministic fakes.
- The bundled 16 kHz English fixture validates audio loading and enables an opt-in
  real-model test.
- Benchmark records use the versioned `BenchmarkResult` schema.

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

| Metric | Target | Current published result |
| --- | ---: | --- |
| Hotkey to capture p95 | < 75 ms | Pending instrumented dogfood run |
| Release to insertion p50 | < 200 ms | Pending instrumented dogfood run |
| Release to insertion p95 | < 500 ms | Pending instrumented dogfood run |
| Sequential reliability | 500 cycles | Passing in automated test |
| Idle CPU | Near zero | Pending release-build sample |
| Warm-model memory | Reported separately | Pending release-build sample |

Unmeasured rows are release evidence gaps, not implied passes.

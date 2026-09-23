# Speech accuracy benchmark

A development-only harness, separate from the app's package graph, that measures word
error rate (WER) for the speech engine Vani ships. It runs the same Core ML
configuration as `FluidAudioSpeechRecognizer` (Parakeet TDT v2, CPU + Neural Engine).

```bash
# 1. LibriSpeech test-clean and test-other (about 670 MB, CC BY 4.0)
mkdir -p librispeech && cd librispeech
for s in test-clean test-other; do curl -L https://www.openslr.org/resources/12/$s.tar.gz | tar xz; done
cd ..
# 2. 400 random utterances per set plus 15 long-form recordings per set (60–310 s),
#    built from consecutive utterances with 0.3 s gaps (seed 7).
python3 Benchmarks/make_corpus.py
# 3. Transcribe and score. FLUIDAUDIO_VERSION selects the dependency under test;
#    ASR_MODEL=unified or unified-fp16 evaluates Parakeet Unified instead of v2.
(cd Benchmarks/AsrBench && FLUIDAUDIO_VERSION=0.15.8 swift build -c release)
Benchmarks/AsrBench/.build/release/AsrBench manifest.tsv hyp.tsv models-dir
python3 Benchmarks/wer.py hyp.tsv
```

Scoring lowercases, strips punctuation and maps single-digit numerals to words; it
does not otherwise normalize spelling. Results are in [docs/BENCHMARKS.md](../docs/BENCHMARKS.md).

The same LibriSpeech test-clean folder drives the opt-in 30-minute meeting test
(`VANI_LIBRISPEECH_DIR=…/LibriSpeech/test-clean`); see "Long meetings" in
[docs/BENCHMARKS.md](../docs/BENCHMARKS.md) for that and the two-hour soak commands.

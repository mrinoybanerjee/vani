# Third-Party Notices

## FluidAudio

Vani uses [FluidAudio](https://github.com/FluidInference/FluidAudio), version 0.15.8,
under the Apache License 2.0. FluidAudio's own transitive notices remain available in
its source distribution.

FluidAudio 0.15.7 and later link
[NemoTextProcessing](https://github.com/FluidInference/text-processing-rs) v0.3.0, a
prebuilt Rust text-normalization library under the Apache License 2.0. SwiftPM verifies
its archive against the checksum declared by the pinned FluidAudio release. Vani does
not call it; it is linked because toolchains before Swift 6.2 cannot omit it.

## Parakeet TDT 0.6B V2 Core ML

The model downloaded during setup is
[FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml),
licensed under Creative Commons Attribution 4.0. It is based on NVIDIA's Parakeet TDT
model; Core ML conversion and Swift integration are credited to FluidInference.

Vani verifies model artifacts against repository revision
`ee09c569f73759e6d44c9bd16766f477b2b36d39` before loading them.

Vani does not redistribute model weights in this repository or app bundle.

## Optional local meeting summaries

Meeting summaries use a separately installed [Ollama](https://github.com/ollama/ollama)
service, whose source is [MIT licensed](https://github.com/ollama/ollama/blob/main/LICENSE),
and the [Qwen3 4B model](https://ollama.com/library/qwen3:4b), published under Apache-2.0.
The configured Ollama model tag is `qwen3:4b`. Neither Ollama nor these model weights
are bundled in Vani; their installation and model storage are managed separately.

## LibriSpeech test fixture

`Tests/VaniCoreTests/Fixtures/librispeech-1272-128104-0000.wav` is derived from
the [LibriSpeech](https://www.openslr.org/12) `dev_clean` sample
`1272-128104-0000`, distributed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
LibriSpeech was prepared by Vassil Panayotov, Guoguo Chen, Daniel Povey, and
Sanjeev Khudanpur from public-domain LibriVox recordings.

Reference transcript: "MISTER QUILTER IS THE APOSTLE OF THE MIDDLE CLASSES AND WE
ARE GLAD TO WELCOME HIS GOSPEL".

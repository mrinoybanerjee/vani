<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Vani app icon">
</p>

# Vani

Private, native voice typing for Apple Silicon Macs.

Hold a shortcut, speak English, and release. Vani transcribes on your Mac and
inserts the result into the app you were using. There is no account, telemetry,
cloud transcription, or generative rewriting.

## Status

Vani is a functional development beta for macOS 14 or newer on Apple Silicon. The
core workflow, recovery paths, native UI, deterministic audio fixture, and 500-cycle
reliability harness are implemented. Public releases remain blocked on Developer ID
credentials and notarization.

## What Works

- Hold Right Option, Right Command, or Fn to dictate
- One-time English Parakeet TDT v2 model download
- Exact model-revision manifest with per-file SHA-256 verification
- Local microphone capture and Core ML transcription
- Direct Accessibility insertion with a verified paste fallback
- Transcript recovery when focus, insertion, or the clipboard changes
- Optional bounded history, disabled by default
- Personal phrase dictionary and launch-at-login setting
- Metadata-only diagnostics with no transcript or audio content

## Run Locally

Requirements: Apple Silicon, macOS 14+, Swift 6, and about 1 GB of free memory for
the warm speech model.

```bash
git clone https://github.com/mrinoybanerjee/vani.git
cd vani
./scripts/test.sh
./scripts/install-local.sh
```

Vani opens in the menu bar. Grant Microphone and Accessibility access, download the
English model once, then hold Right Option while speaking. Development builds are
ad-hoc signed; see [Building](docs/BUILDING.md) for the macOS permission caveat.

## Engineering

Vani is a small Swift 6 modular monolith. The real-time audio callback writes into a
preallocated bounded buffer; model work, text cleanup, insertion, storage, and UI
remain outside that callback. Dependencies are exact-pinned in `Package.resolved`.

- [Architecture](docs/ARCHITECTURE.md)
- [Project provenance](docs/PROVENANCE.md)
- [Privacy contract](PRIVACY.md)
- [Security model](docs/SECURITY_MODEL.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Contributing](CONTRIBUTING.md)

## License

Apache-2.0. The downloaded speech model is CC BY 4.0. See
[third-party notices](THIRD_PARTY_NOTICES.md).

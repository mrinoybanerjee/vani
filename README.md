<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Vani app icon">
</p>

# Vani

A private, local, and free Wispr Flow alternative for Apple Silicon Macs.

Hold a shortcut, speak English, and release. Vani transcribes on your Mac and
inserts the result into the app you were using. There is no account, telemetry,
cloud transcription, or generative rewriting.

## Status

Vani is a functional source beta for macOS 14 or newer on Apple Silicon. The core
workflow, recovery paths, native UI, deterministic audio fixture, and 500-cycle
reliability harness are implemented. Free source releases can be built locally;
prebuilt Gatekeeper-trusted downloads still require paid Developer ID signing and
Apple notarization.

## What Works

- Hold Left Fn to dictate by default; Left Control, Right Option, and Right Command are available
- Short local sound cues confirm when recording actually starts and stops
- One-time English Parakeet TDT v2 model download
- Exact model-revision manifest with per-file SHA-256 verification
- Local microphone capture and Core ML transcription
- Dictations up to 20 minutes, with a one-minute warning and automatic transcription
  at the limit
- Process-bound paste delivery with app-scoped Accessibility verification
- Native Accessibility refusal for password and secure text fields
- Clipboard-preserving recovery when focus, insertion, or the clipboard changes
- Memory-only Last Transcript controls with Control-Command-V paste and
  Control-Command-C copy shortcuts
- Voice-triggered snippets with multiline expansions
- Opt-in local Smart Formatting for conservative fillers, spoken punctuation,
  sentence casing, and line breaks
- Optional bounded history, disabled by default
- Personal phrase dictionary and launch-at-login setting
- Opt-in local learning from corrections, with transparent delete and reset controls
- Optional experimental acoustic vocabulary boosting for repeatedly corrected terms
- Metadata-only diagnostics with no transcript or audio content
- Public-repository Swift CodeQL analysis and weekly dependency updates

## Run Locally

Requirements: Apple Silicon, macOS 14+, Swift 6, 3 GB of free disk space, and about
1 GB of free memory for normal dictation. Allow roughly 1.5 GB of free memory when
using the full 20-minute recording limit. Install Apple's command-line developer tools
first if `xcode-select -p` fails:

```bash
xcode-select --install
```

Vani supports input devices configured at up to 48 kHz. If a professional audio
interface uses a higher rate, select 48 kHz in Audio MIDI Setup before recording.

Then clone, check the Mac, and install:

```bash
git clone https://github.com/mrinoybanerjee/vani.git
cd vani
./scripts/doctor.sh
./scripts/install-local.sh
```

The first source build can take several minutes. After Vani opens in the menu bar:

1. Allow Microphone, Accessibility, and Input Monitoring when Vani requests them.
2. Download the verified 443 MiB English model once. It is the only required network
   download after the source dependencies are resolved.
3. In System Settings > Keyboard, set "Press Globe key to" to "Do Nothing."
4. Hold Left Fn, speak, then release to insert text. Choose Left Control, Right Option,
   or Right Command in Settings if you prefer, and turn sound feedback off there if needed.

Snippets and Smart Formatting are available in Settings. Smart Formatting is off by
default; enabling it recognizes `comma`, `period` or `full stop`, `question mark`,
`exclamation mark` or `exclamation point`, `colon`, `semicolon`, `new line` or
`next line`, and `new paragraph` or `next paragraph`. It removes only standalone `um`,
`uh`, and `erm` fillers and leaves links, email addresses, and snippet expansions
unchanged. Spoken command words are necessarily interpreted as commands while the
setting is on; turn it off when you need those words literally.

Learning is also off by default. After dictation, **Teach** lets you correct the last
transcript. Vani stores only the changed phrases on this Mac, never correction audio.
After a term is confirmed twice, the optional experimental 98 MiB vocabulary model can use acoustic
evidence for harder names and terminology. The model is not required for dictation.

## Updating Vani

Update an existing clone directly from `main`:

```bash
cd ~/vani
git status --short
```

If that command prints nothing, continue:

```bash
git switch main
git pull --ff-only origin main
./scripts/install-local.sh
```

If it prints any files, stop and review those local changes before pulling. The
installer replaces `/Applications/Vani.app` atomically and keeps the downloaded model,
settings, snippets, dictionary, and optional history.

### Keep permissions across updates

macOS attaches Microphone, Accessibility, and Input Monitoring permissions to the
app's signing identity. Without the free local `Vani Local Development` identity,
each source rebuild is ad-hoc signed and macOS can treat it as a different app. Create
the identity once by following [Stable local signing](docs/BUILDING.md#stable-local-signing)
before updating regularly. No paid Apple Developer membership is required.

If permissions disappeared after an update, or their switches will not stay enabled,
follow [Permissions stopped working after an update](docs/TROUBLESHOOTING.md#permissions-stopped-working-after-an-update).

## Engineering

Vani is a small Swift 6 modular monolith. The real-time audio callback writes into
bounded, preallocated memory pages; additional pages are reserved away from the audio
thread only while a long recording is active. Model work, text cleanup, insertion,
storage, and UI remain outside that callback. Dependencies are exact-pinned in
`Package.resolved`.

- [Architecture](docs/ARCHITECTURE.md)
- [Project provenance](docs/PROVENANCE.md)
- [Privacy contract](PRIVACY.md)
- [Security model](docs/SECURITY_MODEL.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Building and local signing](docs/BUILDING.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Uninstalling](docs/UNINSTALLING.md)
- [Contributing](CONTRIBUTING.md)

## License

Apache-2.0. The downloaded speech model is CC BY 4.0. See
[third-party notices](THIRD_PARTY_NOTICES.md).

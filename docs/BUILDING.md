# Building

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Swift 6 command-line tools or current Xcode
- Git

## Development

```bash
swift package resolve
./scripts/lint.sh
./scripts/test.sh
./scripts/run-dev.sh
```

`run-dev.sh` builds an ad-hoc signed app at `dist/Vani.app` and opens it. Install a
release-mode local build with:

```bash
./scripts/install-local.sh
```

Set `INSTALL_ROOT` to install somewhere other than `/Applications`.

## Permissions and signatures

macOS grants Microphone and Accessibility access to a signed app identity. Rebuilding
an ad-hoc development app can require removing and granting those permissions again.
A stable public installation requires a Developer ID signed and notarized release.

## Model integration test

Normal CI does not download the speech model. After the model is installed locally,
run the bundled English fixture through the real engine with:

```bash
VANI_RUN_MODEL_TESTS=1 swift test --filter bundledEnglishFixtureTranscribesLocally
```

## Environment variables

| Variable | Purpose |
| --- | --- |
| `CONFIGURATION` | `debug` or `release` app build |
| `CODESIGN_IDENTITY` | Developer ID identity, or `-` for ad-hoc signing |
| `VERSION` | Numeric release version written into the app bundle |
| `BUILD_NUMBER` | Numeric bundle build number |
| `INSTALL_ROOT` | Local destination, default `/Applications` |
| `VANI_QA_WINDOW=1` | Show the menu content in a window for UI automation |

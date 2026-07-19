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

`run-dev.sh` builds an app at `dist/Vani.app` and opens it. Install a release-mode
local build with:

```bash
./scripts/install-local.sh
```

Set `INSTALL_ROOT` to install somewhere other than `/Applications`.

## Permissions and signatures

macOS grants Microphone and Accessibility access to a signed app identity. An ad-hoc
signature is based on the current executable, so its identity changes after a rebuild
and macOS can ask for both permissions again.

When the login keychain contains a valid code-signing identity named
`Vani Local Development`, local builds select it automatically. This keeps Vani's
identity stable across rebuilds, so permissions normally need to be granted only once.
Set `CODESIGN_IDENTITY=-` to force an ad-hoc build, or set it to another identity to
override the automatic selection.

A self-signed local identity is only for development on the Mac that owns its private
key. Public downloads still require an Apple Developer ID signature and notarization.

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
| `CODESIGN_IDENTITY` | Signing identity override, or `-` for ad-hoc signing |
| `VERSION` | Numeric release version written into the app bundle |
| `BUILD_NUMBER` | Numeric bundle build number |
| `INSTALL_ROOT` | Local destination, default `/Applications` |
| `VANI_QA_WINDOW=1` | Show the menu content in a window for UI automation |

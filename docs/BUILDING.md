# Building

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Swift 6 command-line tools or current Xcode
- Git
- 3 GB of free disk space for build artifacts and the speech model

If the Apple developer tools are not installed:

```bash
xcode-select --install
```

Verify the machine before building:

```bash
./scripts/doctor.sh
```

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

macOS grants Microphone, Accessibility, and Input Monitoring access to a signed app
identity. An ad-hoc
signature is based on the current executable, so its identity changes after a rebuild
and macOS can ask for those permissions again.

When the login keychain contains a valid code-signing identity named
`Vani Local Development`, local builds select it automatically. This keeps Vani's
identity stable across rebuilds, so permissions normally need to be granted only once.
Normal launches do not require permissions to be reset. macOS may ask again if the
bundle identifier or signing identity changes, the app is replaced by a differently
signed build, or the system privacy database is reset.
Set `CODESIGN_IDENTITY=-` to force an ad-hoc build, or set it to another identity to
override the automatic selection.

A self-signed local identity is only for development on the Mac that owns its private
key. Public downloads still require an Apple Developer ID signature and notarization.

### Stable local signing

This optional setup is recommended for contributors who rebuild Vani regularly. It
creates a private key in the login keychain. Never export or commit that private key.
Apple documents the underlying flow in
[Create self-signed certificates in Keychain Access](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac).

1. Open Keychain Access with Spotlight.
2. Choose Keychain Access > Certificate Assistant > Create a Certificate.
3. Set the name to `Vani Local Development`.
4. Choose `Self Signed Root` as the identity type and `Code Signing` as the
   certificate type.
5. Create the certificate in the login keychain.
6. Verify it from the repository:

```bash
security find-identity -v -p codesigning
./scripts/doctor.sh
```

The identity should appear exactly as `Vani Local Development`. The first build may
ask to access its private key; choose `Always Allow` for `/usr/bin/codesign`. Reinstall
Vani and grant its three permissions once after changing identities. The certificate
is local development infrastructure, not a substitute for Developer ID distribution.

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
| `VANI_SKIP_OPEN=1` | Install without launching, for isolated automation |
| `VANI_QA_WINDOW=1` | Show the menu content in a window for UI automation |

## Local data

- App: `/Applications/Vani.app`
- Settings: `~/Library/Preferences/com.mrinoy.vani.plist`
- Optional history: `~/Library/Application Support/Vani/history.json`
- Cache: `~/Library/Caches/com.mrinoy.vani`
- Shared speech model: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2`

The speech model is about 443 MiB and is shared through FluidAudio's model directory.
Vani checks its exact file list, byte counts, and SHA-256 hashes before loading it.

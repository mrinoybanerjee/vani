# Releasing

## Required repository secrets

- `DEVELOPER_ID_APPLICATION_P12`: base64-encoded Developer ID Application certificate
- `DEVELOPER_ID_APPLICATION_PASSWORD`: certificate export password
- `CI_KEYCHAIN_PASSWORD`: random password for the ephemeral runner keychain
- `APPLE_ID`: Apple developer account email
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

Protect the `release` GitHub environment with required reviewers. Never put signing
material in repository files, artifacts, logs, or pull requests.

## Release process

1. Ensure CI is green on `main`.
2. Update `CHANGELOG.md` and `Resources/Info.plist`.
3. Create and push a signed semantic tag such as `v0.1.0`.
4. The Release workflow builds, Developer ID signs, notarizes, staples, assesses,
   archives, checksums, and publishes the app.
5. Download the release on a separate Mac, verify the checksum, and complete one
   clean-install dictation before announcing it.

The workflow fails closed when any signing or notarization credential is absent.

# Releasing

## Source beta releases

Source releases are free and do not need Apple credentials. They are GitHub
prereleases with source archives and local build instructions, not downloadable app
bundles.

1. Ensure CI is green on `main`.
2. Update `CHANGELOG.md` and `Resources/Info.plist`.
3. Create and push an annotated semantic tag such as `v0.1.0` from `main`.
4. The Release workflow validates the tag and source commit, reruns lint and tests,
   and publishes the source beta.

Users build these releases on their own Mac with `./scripts/install-local.sh`. A local
self-signed identity can keep privacy permissions stable on that Mac, but it is not a
substitute for Apple Developer ID distribution.

## Optional signed binary releases

Gatekeeper-trusted public app bundles require a paid Apple Developer Program
membership. Set the `APPLE_DISTRIBUTION_ENABLED` repository variable to `true` and
configure these repository secrets only when that distribution path is available:

- `DEVELOPER_ID_APPLICATION_P12`: base64-encoded Developer ID Application certificate
- `DEVELOPER_ID_APPLICATION_PASSWORD`: certificate export password
- `CI_KEYCHAIN_PASSWORD`: random password for the ephemeral runner keychain
- `APPLE_ID`: Apple developer account email
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

Protect the `release` GitHub environment with required reviewers. Never put signing
material in repository files, artifacts, logs, or pull requests.

The signed release job imports the certificate into an ephemeral keychain, builds with
the hardened runtime, notarizes and staples the app, verifies it with Gatekeeper,
attaches the app and checksum to the existing source release, and promotes the release
out of prerelease status. It fails closed when any signing or notarization credential
is absent.

## Signed release validation

Download the binary release on a separate Mac, verify the checksum, and complete one
clean-install dictation before announcing it as a public binary release. A clean
GitHub-hosted runner proves that the source builds; it does not replace this physical
Mac permission and dictation test.

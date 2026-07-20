# Security Policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose audio,
transcripts, clipboard contents, or local files. Until a dedicated security email
is configured, use GitHub private vulnerability reporting for the repository.

## Release requirements

- Hardened runtime
- Developer ID signing and Apple notarization
- Pinned dependencies
- SHA-256 checksums for downloads
- GitHub artifact attestation
- No high or critical unresolved security findings

Ad-hoc development builds are suitable for local testing but are not public release
artifacts. A supported public build must pass the release workflow, including
Developer ID signing, Apple notarization, stapling, Gatekeeper assessment, checksum
generation, and provenance attestation when the repository is public.

See [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md) for trust boundaries and known
limitations.

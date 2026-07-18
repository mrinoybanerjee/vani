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

Pre-alpha builds are development artifacts and are not yet supported for sensitive
work.

# Contributing

Vani v1 is intentionally narrow: Apple Silicon macOS, English, local inference, and
reliable text insertion. Start with an issue before adding cloud services, accounts,
telemetry, plugins, generative rewriting, another platform, or another speech engine.

## Development

1. Read `docs/ARCHITECTURE.md`, `PRIVACY.md`, and `SECURITY.md`.
2. Create a focused branch from `main`.
3. Add tests for changed behavior.
4. Run `./scripts/lint.sh`, `./scripts/test.sh`, and `./scripts/build-app.sh`.
5. Explain user-visible behavior, privacy impact, and manual QA in the pull request.

Keep the real-time audio callback bounded. Do not log transcript, audio, clipboard,
or focused-field content. Preserve recovery behavior whenever insertion cannot be
proven.

## Pull requests

Prefer one behavior change per pull request. CI must pass. Security-sensitive changes
need a threat-model note and focused tests. UI changes need keyboard, VoiceOver,
Reduce Motion, light/dark appearance, and compact-width checks where relevant.

By contributing, you agree that your contribution is licensed under Apache-2.0.

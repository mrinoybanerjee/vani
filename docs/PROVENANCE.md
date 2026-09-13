# Provenance

Vani is an independent implementation. LocalFlow, Wispr Flow, Granola and other voice products were
used only to understand user workflows, product expectations, and public technical
tradeoffs. Their source code was not copied into this repository.

The production code is native Swift built around Apple frameworks and the exact-pinned
FluidAudio package. Third-party code, model, and test-fixture licensing is recorded in
`THIRD_PARTY_NOTICES.md` and `Package.resolved`.

The approved meeting extension calls a separately installed local Ollama service with
`qwen3:4b`. Vani does not bundle either runtime or weights. The [redesign research](REDESIGN_2026-09-12.md)
records the public product references and distinguishes observed UI from vendor claims.

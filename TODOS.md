# Roadmap

## Next Candidates

- Extend meeting hardware validation to long real calls, audio-device transitions and
  VoiceOver. A brief installed v0.4.0 microphone + Mac-audio capture, local summary and
  post-meeting TextEdit dictation passed on September 12, 2026. The v0.4.1 follow-up
  uses deterministic regression tests; see [meeting validation](docs/MEETINGS_DESIGN.md#validation-boundaries).
- Evaluate Parakeet Unified EN 0.6B as the default model (1.91% vs 2.22% WER on
  LibriSpeech test-clean single utterances; see docs/BENCHMARKS.md) and live
  streaming preview, including a pinned manifest and personalization path
- Real-time input level for the recording overlay

## Longer Term

These items are intentionally outside v1.

- Multilingual transcription
- Windows, Linux, iOS, or Intel Mac support
- Cloud transcription or synchronization
- Generative rewriting and custom prompts
- Command or assistant mode
- Person-level speaker identification, calendar integration, pause/resume and cross-meeting chat
  (local meeting capture and summaries are implemented for v0.4.0; physical acceptance remains above)
- Team administration
- Plugin or model marketplace
- Background auto-updater
- Screen or surrounding-text context awareness
- Multiple simultaneous speech engines

# Roadmap

## Next Candidates

- Finish hardware validation that could not be automated on September 23, 2026: Bluetooth
  headsets connecting mid-recording, sleep during a meeting, multi-hour live calls, a true
  sample-rate mismatch between two physical microphones, and a full session with a VoiceOver
  user. Microphone switches and removal are verified; see
  [hardware checks](docs/BENCHMARKS.md#hardware-checks--september-23-2026) and the opt-in
  `VANI_RUN_HARDWARE_TESTS` suite.
- Live transcript preview while dictating, using FluidAudio's streaming Parakeet Unified
  path (the offline Unified model is the default since v0.7.0)
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

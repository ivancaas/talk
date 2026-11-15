# Changelog

All notable changes to Talk. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-15

First public release.

### Added
- Menu-bar dictation: ⌥Space to start and stop, text pasted into the focused app.
- Parakeet TDT 0.6B v3 on the Neural Engine via FluidAudio: 25 languages, detected automatically, fully local.
- Setup window with live checks for the microphone, Accessibility and the speech model (download progress).
- Settings window: shortcut recorder, pill position, launch at login, keep-warm time, live memory use.
- The model runs in a helper process that exits after each dictation, so Talk idles at about 10 MB.
- `talk transcribe` command for audio, video and video URLs: text, timestamps, SRT, VTT and JSON.
- Quiet speech is raised to a normal level before transcription.
- Dictations stop by themselves after 15 minutes or when the microphone goes away, and keep what was heard.
- Paste works with any keyboard layout and marks the clipboard entry as transient for clipboard managers.
- `talk-transcribe` skill for Claude Code and other AI agents, installed with the app.

[1.0.0]: https://github.com/ivancaas/talk/releases/tag/v1.0.0

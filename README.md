# Talk

Menu-bar dictation for macOS. Press **⌥Space**, speak, press **⌥Space** again: the text is pasted into the focused app.

- Engine: Parakeet TDT 0.6B v3 (CoreML, Neural Engine) via FluidAudio 0.18.2, multilingual, fully local.
- Memory: the model is loaded when you start dictating (≈0.25 s, overlapped with your speech) and released right after the text is pasted. The mic is only open while recording.
- Status pill: a small floating pill on the screen under the mouse shows Listening (dots follow your voice) → Transcribing… → Pasted. It never takes focus.
- Model files: `~/Library/Application Support/Talk/Models/` (~600 MB, downloaded once).

## Requirements
- Apple Silicon Mac (M1 or later), macOS 14+.
- Swift 6 toolchain: Xcode 16+ or just the Command Line Tools (`xcode-select --install`).
- Internet on first build (fetches FluidAudio) and first launch (downloads the model, ~600 MB, once).

## Build / install
    git clone https://github.com/ivancaas/talk.git && cd talk
    scripts/build.sh        # → /Applications/Talk.app
    open /Applications/Talk.app

Talk appears in the menu bar (no Dock icon). On first launch it downloads the model in the background
(a few minutes, depending on your connection); the first dictation waits for it to finish.
First run asks for Microphone and Accessibility (needed to paste): grant both (if pasting still doesn't work, quit and reopen Talk).

Signing: the first build creates a self-signed "Talk Local Signing" certificate in your login keychain
(macOS may ask once to let codesign use it: choose Always Allow). Every build is signed with it, so the
Accessibility permission survives rebuilds; no Apple developer account needed.

## Transcribe files from the command line
`scripts/build.sh` also links `~/.local/bin/talk` (override with `TALK_BIN_DIR`). Same model, fully local; works
without the menu-bar app running (it loads its own copy of the model, ~0.2 s warm).

    talk transcribe meeting.m4a                      # plain text to stdout, paragraphs at long pauses
    talk transcribe -t lecture.mp4                   # one line per sentence, [hh:mm:ss] prefix
    talk transcribe -f srt -o video.srt video.mov    # subtitles (also: vtt, json; -w adds word timings to json)
    talk transcribe -f json -d out/ *.mp3            # one file per input into out/
    talk transcribe "https://www.youtube.com/watch?v=..."   # fetched with yt-dlp

- Inputs: anything AVFoundation reads (wav, mp3, m4a, aac, flac, aiff, mp4, mov…); mkv, webm, ogg, opus etc. go
  through `ffmpeg` (`brew install ffmpeg`). URLs need `yt-dlp`.
- Text goes to stdout, progress to stderr (`-q` silences it); exit code 1 if any input failed. Made for scripts and
  AI agents: `talk transcribe --help` documents every option.
- Speed: a 22-minute file took 4 s (≈330× real time) and peaked at 380 MB.

## Config (`~/.config/talk/config.json`, restart Talk after editing)
    { "hotkey": "opt+space", "pill": "bottom", "unloadAfterSeconds": 0 }

`hotkey`: e.g. `ctrl+opt+d`, `f13`, `cmd+shift+space`. `pill`: `bottom` or `top`. `unloadAfterSeconds`: keep the model warm for N s after a dictation.

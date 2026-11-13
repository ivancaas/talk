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
Ad-hoc signed: after a rebuild, re-tick Talk in System Settings → Privacy & Security → Accessibility.

## Config (`~/.config/talk/config.json`, restart Talk after editing)
    { "hotkey": "opt+space", "pill": "bottom", "unloadAfterSeconds": 0 }

`hotkey`: e.g. `ctrl+opt+d`, `f13`, `cmd+shift+space`. `pill`: `bottom` or `top`. `unloadAfterSeconds`: keep the model warm for N s after a dictation.

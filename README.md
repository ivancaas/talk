# Talk

Menu-bar dictation for macOS. Press **⌥Space**, speak, press **⌥Space** again: the text is pasted into the focused app.

- Engine: Parakeet TDT 0.6B v3 (CoreML, Neural Engine) via FluidAudio 0.18.2, multilingual, fully local.
- Memory: the model is loaded when you start dictating (≈0.25 s, overlapped with your speech) and released right after the text is pasted. The mic is only open while recording.
- Status pill: a small floating pill on the screen under the mouse shows Listening (dots follow your voice) → Transcribing… → Pasted. It never takes focus.
- Model files: `~/Library/Application Support/Talk/Models/` (~600 MB, downloaded once).

## Build / install
    scripts/build.sh        # → /Applications/Talk.app

First run asks for Microphone and Accessibility (needed to paste). Ad-hoc signed: after a rebuild,
re-tick Talk in System Settings → Privacy & Security → Accessibility.

## Config (`~/.config/talk/config.json`, restart Talk after editing)
    { "hotkey": "opt+space", "pill": "bottom", "unloadAfterSeconds": 0 }

`hotkey`: e.g. `ctrl+opt+d`, `f13`, `cmd+shift+space`. `pill`: `bottom` or `top`. `unloadAfterSeconds`: keep the model warm for N s after a dictation.

## Self-test
    .build/release/Talk --render-pill            # writes /tmp/pill-*.png for every pill state
    .build/release/Talk --transcribe some.wav    # prints text, load/transcribe ms, memory

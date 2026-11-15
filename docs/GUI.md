# Talk's windows

Talk is a menu-bar app with two small windows, both SwiftUI hosted in AppKit windows. Each is built when
you ask for it and dropped when you close it (view, model and its one-second timer), so an idle Talk holds
no window and runs no timer. System fonts, SF Symbols and standard controls only; light and dark follow
the system.

## Menu

    Press ⌥Space to dictate        status line, worked out when the menu opens
    ──────────────────────────
    Setup…
    Settings…              ⌘,
    ──────────────────────────
    About Talk
    Quit Talk              ⌘Q

The status line names the first thing in the way: `config.json can't be read`, `Setup needed: Microphone`,
`Setup needed: Accessibility`, `Downloading speech model… 42 %`, `Shortcut ⌥Space is unavailable`.
Launch at login lives in Settings. While a Talk window is in front, ⌘, ⌘W, ⌘Q and copy/paste work.

## Setup (`SetupWindow.swift`)

Shown at launch when anything dictation needs is missing, from the menu, and when a dictation fails for a
reason Setup can fix (microphone denied, pasting without Accessibility, model not downloaded yet).

    ┌ Talk Setup ───────────────────────────────────────────────┐
    │ [icon]  Set Up Talk                                        │
    │         Press ⌥Space, speak, press ⌥Space again. …        │
    ├────────────────────────────────────────────────────────────┤
    │ 🎙  Microphone                                  [Allow…]   │
    │     To hear you. Open only while you dictate.              │
    ├────────────────────────────────────────────────────────────┤
    │ ♿  Accessibility                                     ✓    │
    │     To paste the text into the app you are typing in.      │
    ├────────────────────────────────────────────────────────────┤
    │ ∿  Speech model                        ▓▓▓▓░░░░░  42 %     │
    │     Downloading about 600 MB, once.                        │
    ├────────────────────────────────────────────────────────────┤
    │ 1 of 3 ready. This list updates by itself.        [Done]   │
    └────────────────────────────────────────────────────────────┘

| Row | Ready when | Button while not ready |
|---|---|---|
| Microphone | access granted | `Allow…` (system prompt) the first time; `Open System Settings…` once denied |
| Accessibility | Talk is ticked in Privacy & Security | `Grant…` (system prompt, adds Talk to the list), then `Open System Settings…` |
| Speech model | all files on disk | progress bar while downloading; `Download`, or `Try Again` with the error |
| Settings file (only when broken) | never | `Open Settings…` |
| Shortcut (only when macOS refused it) | never | `Change…` |

A ready row shows a green check instead of a button. The state is read once a second while the window is
open; download progress is pushed as it arrives. This is the only place that asks for Accessibility:
pasting no longer prompts.

## Settings (`SettingsWindow.swift`, ⌘,)

    ┌ Talk Settings ────────────────────────────────────────────┐
    │ ┌────────────────────────────────────────────────────────┐ │
    │ │ Dictation shortcut                       [  ⌥Space  ] │ │
    │ │ Status pill                    Bottom of the screen ⌄ │ │
    │ │ Launch at login                                   ( ○) │ │
    │ └────────────────────────────────────────────────────────┘ │
    │ Lightweight by design                                      │
    │ ┌────────────────────────────────────────────────────────┐ │
    │ │ Memory in use now                               27 MB │ │
    │ │ Speech model                               Not loaded │ │
    │ │ Keep the model loaded after dictating          0 s ⌃⌄ │ │
    │ └────────────────────────────────────────────────────────┘ │
    │ The speech model is loaded when you start dictating and …  │
    │ ┌────────────────────────────────────────────────────────┐ │
    │ │ Settings file   ~/.config/talk/config.json [Show in F…]│ │
    │ └────────────────────────────────────────────────────────┘ │
    │ Changes apply right away.                                  │
    └────────────────────────────────────────────────────────────┘

- **Dictation shortcut**: click, then press the keys (`Press shortcut…`). Needs ⌘, ⌥ or ⌃ plus a key, or a
  function key alone; Esc cancels. The current shortcut is released while recording so it can be pressed
  again. If macOS refuses the new one, the old one stays and a line says so.
- **Status pill**, **Keep the model loaded**: the same `pill` and `unloadAfterSeconds` keys as before.
- **Launch at login**: the system login item (`SMAppService`); needs the installed app.
- **Memory in use now**: the process's `phys_footprint` (what Activity Monitor calls Memory), refreshed
  every second, next to whether the model is in memory.
- Every change is applied to the running app and written to `~/.config/talk/config.json`. No restart.
- **Broken config.json**: a banner on top gives the reason (`“hotkey” has the wrong type`, `Not valid
  JSON: …`) with `Open File`, `Reload` and `Use Defaults` (keeps the old file as `config.json.bak`).
  Talk runs on defaults and does not overwrite the file until you pick one; the other controls are off.

## Status pill

Two more states: `Loading model…` when you stop before the model has finished loading, and
`Downloading speech model… 42 %` when you press the shortcut before the first download is done (Talk does
not record then). A denied microphone says `Microphone access is off: see Talk Setup` and opens Setup,
instead of recording silence and reporting `Nothing heard`.

## Checks

    .build/release/Talk --check-gui /tmp/talk-gui   # shortcut and config logic, PNG of every window state
    .build/release/Talk --measure-idle              # memory: launch, pill, windows open, windows closed

Both end with `RESULT pass=N fail=M`. Neither registers the global shortcut, loads the model or prompts,
so they are safe to run next to an installed Talk. `--measure-idle` shows a second menu-bar icon and the
two windows for a few seconds.

Memory (phys_footprint, M-series Mac, macOS 15): 9 MB after launch (8.5 MB before these windows existed), 13 MB once the status pill has been
shown, 28 MB with both windows open, 27 MB after closing them. The windows' models, views and timers are
freed on close (the check asserts it); what remains is AppKit and SwiftUI state that macOS sets up on
first use and keeps for the life of the process (about 6 MB for Setup, 11 MB for Settings).

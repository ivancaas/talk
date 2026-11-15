# Contributing to Talk

Thanks for helping! Bug reports, fixes and small improvements are very welcome.

## Before you start
- For anything larger than a small fix, please open an issue first so we can agree on the approach.
- Talk's promises are **local only** and **light when idle**. Changes should keep both: no network calls besides
  the model download, and nothing that keeps the model, the microphone or timers alive between dictations.

## Build and test
Apple Silicon Mac, macOS 14+, Xcode 16+ or the Command Line Tools.

```bash
swift build -c release     # build
swift test                 # unit tests (also run by CI on every pull request)
scripts/build.sh           # install /Applications/Talk.app to try it for real
```

Useful self-checks of the built binary:

```bash
.build/release/Talk --worker-test some.wav other.m4a   # model worker: timings, text, worker exits
.build/release/Talk --check-gui /tmp/talk-gui           # renders the Setup/Settings windows to PNGs
.build/release/Talk --measure-idle                      # idle memory checks
```

## Pull requests
- Keep each pull request to one change, with a short description of what and why.
- Add or update a test when you change logic that can be tested without a microphone.
- Follow the existing style: small types, comments that explain *why*, no new dependencies without discussion.
- Update `CHANGELOG.md` under an "Unreleased" heading.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

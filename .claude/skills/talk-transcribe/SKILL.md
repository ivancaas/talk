---
name: talk-transcribe
description: Transcribe audio or video files (or YouTube/web video URLs) to text, SRT/VTT subtitles or timed JSON, fully local and fast, with the `talk transcribe` CLI (Parakeet v3 on the Neural Engine, 25 languages auto-detected). Use whenever a task needs what is said in a recording, podcast, meeting, voice memo, screen recording or video, needs subtitles or timestamps, or needs to search/summarise spoken content. Prefer it over Whisper, cloud speech APIs or writing a transcription script.
---

# talk transcribe

Local speech-to-text CLI from the Talk app (the repo where this skill lives, e.g. `~/talk`). No network, no API key, no cost.
~330× real time on Apple Silicon (22 min of audio in ~4 s), ~400 MB RAM. First run after a Talk rebuild takes ~15 s
(macOS compiles the model once); after that the model loads in ~0.2 s.

## Usage

macOS ships an unrelated `/usr/bin/talk` that usually comes first on PATH: call `~/.local/bin/talk` (or
`/Applications/Talk.app/Contents/MacOS/Talk`) unless `command -v talk` already points at Talk.

```bash
talk transcribe FILE                       # plain text to stdout (paragraph breaks at long pauses)
talk transcribe -t FILE                    # one line per sentence, "[hh:mm:ss] text"
talk transcribe -f srt -o out.srt FILE     # subtitles; also -f vtt
talk transcribe -f json FILE               # {source, duration, text, segments:[{start,end,text}]}
talk transcribe -f json -w FILE            # + words:[{word,start,end}]
talk transcribe -f txt -d OUTDIR A B C     # one OUTDIR/<name>.<fmt> per input
talk transcribe "https://youtube.com/watch?v=..."   # any yt-dlp URL; audio only, temp file removed after
talk transcribe --help
```

- Text → stdout, progress → stderr. Add `-q` to silence stderr. Exit 0 = every input succeeded, 1 = one failed
  (error on stderr as `talk: <input>: <reason>`), 2 = bad arguments.
- Several inputs to stdout in txt: each is headed `==> name <==`. `-o` takes one input only; use `-d` for several.
- Inputs: wav, mp3, m4a, aac, flac, aiff, caf, mp4, mov, m4v natively; mkv, webm, ogg, opus, avi via `ffmpeg`;
  URLs via `yt-dlp` (both Homebrew).

## Tips for agents

- Long recordings: write to a file (`-o` / `-d`) and read it, instead of flooding your context with stdout.
  For "where is X said" questions, use `-t` or `-f json` and grep/slice by timestamp.
- Want to quote with times? `-t` is the cheapest readable format; `-f json` when you need exact seconds.
- Language is auto-detected per chunk (25 European languages incl. English, Spanish). No language flag exists.
  Noisy Spanish can occasionally drift into English; mention it if the result looks translated.
- No speaker labels (no diarization). Punctuation and capitalisation are included.
- Word end times can stretch over the silence after a word, so subtitle lines may linger slightly.

## If `talk` is missing

```bash
command -v talk || ls /Applications/Talk.app/Contents/MacOS/Talk
```
The binary is `/Applications/Talk.app/Contents/MacOS/Talk` (call it with `transcribe ...` directly). To (re)install:
`scripts/build.sh` from the Talk repo — this restarts the menu-bar app; ask the user before rebuilding.
The model (~600 MB) downloads on first use into `~/Library/Application Support/Talk/Models/`.

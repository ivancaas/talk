import AVFoundation
import FluidAudio
import Foundation

/// `talk transcribe`: audio/video files (or URLs) → text, SRT, VTT or JSON. Runs fully local, same model as dictation.
enum TranscribeCLI {
    static let usage = """
        Usage: talk transcribe [options] <file-or-url>...

        Transcribes audio or video files on this Mac (Parakeet v3, Neural Engine, 25 languages, auto-detected).
        Reads anything AVFoundation opens (wav, mp3, m4a, aac, flac, aiff, caf, mp4, mov, m4v); other containers
        (mkv, webm, ogg, opus, avi…) go through ffmpeg if it is installed. http(s) URLs are fetched with yt-dlp.

        Options:
          -f, --format FMT   txt (default), srt, vtt, json
          -t, --timestamps   txt only: prefix each line with [hh:mm:ss]
          -o, --output PATH  write to PATH instead of stdout (single input only)
          -d, --out-dir DIR  write <name>.<ext> per input into DIR
          -w, --words        json only: include word-level timings
          -q, --quiet        no progress on stderr
          -h, --help         this help

        Output goes to stdout, progress to stderr. Exit code 0 when every input was transcribed.

        Examples:
          talk transcribe meeting.m4a
          talk transcribe -f srt -o talk.srt video.mp4
          talk transcribe -f json -d out/ *.mp3
          talk transcribe -t "https://www.youtube.com/watch?v=..."
        """

    enum Format: String { case txt, srt, vtt, json }

    struct Options {
        var format = Format.txt
        var timestamps = false
        var output: String?
        var outDir: String?
        var words = false
        var inputs: [String] = []
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < args.count else { throw Failure("\(name) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-f", "--format":
                let v = try value(a)
                guard let f = Format(rawValue: v.lowercased()) else { throw Failure("unknown format \(v) (txt, srt, vtt, json)") }
                o.format = f
            case "-t", "--timestamps": o.timestamps = true
            case "-o", "--output": o.output = try value(a)
            case "-d", "--out-dir": o.outDir = try value(a)
            case "-w", "--words": o.words = true
            case "-q", "--quiet": quietLog = true
            case "-h", "--help": print(usage); exit(0)
            case "--": o.inputs += args[(i + 1)...]; i = args.count
            default:
                if a.hasPrefix("-") && a.count > 1 { throw Failure("unknown option \(a)") }
                o.inputs.append(a)
            }
            i += 1
        }
        guard !o.inputs.isEmpty else { throw Failure("no input files") }
        if o.output != nil && o.inputs.count > 1 { throw Failure("--output takes a single input; use --out-dir for several") }
        return o
    }

    static func run(_ args: [String]) -> Never {
        let opts: Options
        do { opts = try parse(args) } catch {
            FileHandle.standardError.write("talk: \(error.localizedDescription)\n\n\(usage)\n".data(using: .utf8)!)
            exit(2)
        }
        Task { @MainActor in
            let engine = Engine()
            var failed = 0
            for (n, input) in opts.inputs.enumerated() {
                do {
                    let t0 = Date()
                    let (url, name, cleanup) = try await resolve(input)
                    defer { cleanup() }
                    log("[\(n + 1)/\(opts.inputs.count)] decoding \(name)")
                    engine.prepare()  // model loads while the file decodes
                    let samples = try await AudioDecoder.load(url)
                    let seconds = Double(samples.count) / 16000
                    guard samples.count >= 16000 / 4 else { throw Failure("no audio (\(String(format: "%.2f", seconds)) s)") }
                    log("transcribing \(timecode(seconds, sep: ".")) of audio")
                    guard let result = try await engine.transcribeDetailed(samples) else { throw Failure("model unavailable") }
                    let out = render(result, seconds: seconds, source: input, opts: opts)
                    try write(out, input: name, opts: opts, multi: opts.inputs.count > 1)
                    log("done in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s (\(String(format: "%.0f", seconds / max(0.001, Date().timeIntervalSince(t0))))× real time)")
                } catch {
                    failed += 1
                    FileHandle.standardError.write("talk: \(input): \(error.localizedDescription)\n".data(using: .utf8)!)
                }
            }
            exit(failed == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: input

    /// Local path, or an http(s) URL downloaded with yt-dlp into a temp folder (removed afterwards).
    static func resolve(_ input: String) async throws -> (URL, String, () -> Void) {
        guard input.hasPrefix("http://") || input.hasPrefix("https://") else {
            let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("file not found") }
            return (url, url.lastPathComponent, {})
        }
        guard let ytdlp = which("yt-dlp") else { throw Failure("URLs need yt-dlp (brew install yt-dlp)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleanup = { try? FileManager.default.removeItem(at: dir); return }
        log("downloading audio with yt-dlp")
        let (out, status) = try await runProcess(ytdlp, [
            "-f", "bestaudio/best", "--no-playlist", "--quiet", "--no-warnings",
            "-o", dir.appendingPathComponent("%(title).80B [%(id)s].%(ext)s").path,
            "--print", "after_move:filepath", input,
        ])
        let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        guard status == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            cleanup()
            throw Failure("yt-dlp could not fetch the audio (exit \(status))")
        }
        let url = URL(fileURLWithPath: path)
        return (url, url.lastPathComponent, cleanup)
    }

    // MARK: output

    struct JSONOut: Encodable {
        struct Seg: Encodable { let start: Double; let end: Double; let text: String }
        struct Word: Encodable { let word: String; let start: Double; let end: Double }
        let source: String
        let duration: Double
        let text: String
        let segments: [Seg]
        let words: [Word]?
    }

    struct Segment { var start: Double; var end: Double; var text: String }

    /// Groups words into subtitle-sized lines: break on long pauses, after sentence ends, or when a line gets long.
    static func segments(_ result: ASRResult) -> [Segment] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        var segs: [Segment] = []
        var cur: Segment?
        for w in words {
            if var c = cur {
                let gap = w.startTime - c.end
                let dur = c.end - c.start
                let last = c.text.last ?? " "
                let sentenceEnd = ".?!…。？！".contains(last)
                let clauseEnd = ",;:，、".contains(last)
                if gap > 1.0 || (sentenceEnd && dur > 1.5) || (clauseEnd && dur > 6) || dur > 10 || c.text.count > 120 {
                    segs.append(c)
                    cur = Segment(start: w.startTime, end: w.endTime, text: w.word)
                } else {
                    c.text += " " + w.word
                    c.end = w.endTime
                    cur = c
                }
            } else {
                cur = Segment(start: w.startTime, end: w.endTime, text: w.word)
            }
        }
        if let cur { segs.append(cur) }
        return segs
    }

    static func render(_ result: ASRResult, seconds: Double, source: String, opts: Options) -> String {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = segments(result)
        switch opts.format {
        case .txt:
            guard !segs.isEmpty else { return text + "\n" }
            if opts.timestamps {
                return segs.map { "[\(timecode($0.start, sep: nil))] \($0.text)" }.joined(separator: "\n") + "\n"
            }
            return paragraphs(segs) + "\n"
        case .srt:
            return segs.enumerated().map { i, s in
                "\(i + 1)\n\(timecode(s.start, sep: ",")) --> \(timecode(s.end, sep: ","))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + segs.map { s in
                "\(timecode(s.start, sep: ".")) --> \(timecode(s.end, sep: "."))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .json:
            let words = opts.words
                ? buildWordTimings(from: result.tokenTimings ?? []).map {
                    JSONOut.Word(word: $0.word, start: round3($0.startTime), end: round3($0.endTime))
                } : nil
            let obj = JSONOut(
                source: source, duration: round3(seconds), text: text,
                segments: segs.map { JSONOut.Seg(start: round3($0.start), end: round3($0.end), text: $0.text) },
                words: words)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = (try? enc.encode(obj)) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    }

    /// Plain text with a paragraph break at long pauses, so long recordings stay readable.
    static func paragraphs(_ segs: [Segment]) -> String {
        var out = ""
        var prevEnd: Double?
        for s in segs {
            if let p = prevEnd { out += (s.start - p > 2.0) ? "\n\n" : " " }
            out += s.text
            prevEnd = s.end
        }
        return out
    }

    static func write(_ out: String, input: String, opts: Options, multi: Bool) throws {
        var path = opts.output
        if path == nil, let dir = opts.outDir {
            let d = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            path = d.appendingPathComponent((input as NSString).deletingPathExtension + "." + opts.format.rawValue).path
        }
        if let path, path != "-" {
            try out.write(toFile: (path as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            log("wrote \(path)")
        } else {
            let body = multi && opts.format == .txt ? "==> \(input) <==\n\(out)\n" : out
            FileHandle.standardOutput.write(body.data(using: .utf8)!)
        }
    }

    static func timecode(_ t: Double, sep: Character?) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60000 % 60, s = ms / 1000 % 60
        let base = String(format: "%02d:%02d:%02d", h, m, s)
        guard let sep else { return base }
        return base + String(sep) + String(format: "%03d", ms % 1000)
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

// MARK: - decoding

enum AudioDecoder {
    /// Any audio/video file → 16 kHz mono Float32. AVFoundation first, ffmpeg for what it can't open.
    static func load(_ url: URL) async throws -> [Float] {
        do {
            return try await viaAVFoundation(url)
        } catch {
            guard let ffmpeg = which("ffmpeg") else {
                throw TranscribeCLI.Failure("can't decode (\(error.localizedDescription)); install ffmpeg for this format")
            }
            return try await viaFFmpeg(url, ffmpeg)
        }
    }

    static func viaAVFoundation(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscribeCLI.Failure("no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscribeCLI.Failure("can't read") }
        var samples: [Float] = []
        while let buf = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            let len = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: len / 4))
            try samples.withUnsafeMutableBytes { raw in
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: raw.baseAddress! + start * 4)
                if status != kCMBlockBufferNoErr { throw TranscribeCLI.Failure("read error \(status)") }
            }
        }
        if reader.status == .failed { throw reader.error ?? TranscribeCLI.Failure("read failed") }
        return samples
    }

    static func viaFFmpeg(_ url: URL, _ ffmpeg: String) async throws -> [Float] {
        let (data, status) = try await runProcess(ffmpeg, [
            "-nostdin", "-v", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-",
        ])
        guard status == 0 else { throw TranscribeCLI.Failure("ffmpeg could not decode it (exit \(status))") }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Runs a tool, returns its stdout (stderr passes through unless quiet).
func runProcess(_ exe: String, _ args: [String]) async throws -> (Data, Int32) {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            if quietLog { p.standardError = FileHandle.nullDevice }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (data, p.terminationStatus))
        }
    }
}

/// Finds a tool on PATH or in Homebrew's folders (apps launched from Finder get a bare PATH).
func which(_ tool: String) -> String? {
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in path + ["/opt/homebrew/bin", "/usr/local/bin"] {
        let p = dir + "/" + tool
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

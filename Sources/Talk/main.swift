import AppKit
import ServiceManagement

struct Config: Codable {
    var hotkey: String = "opt+space"
    /// "bottom" or "top"
    var pill: String = "bottom"
    /// Seconds to keep the model after a dictation (0 = unload right away).
    var unloadAfterSeconds: Double = 0

    init() {}

    /// Missing keys fall back to defaults, so older config files keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        pill = try c.decodeIfPresent(String.self, forKey: .pill) ?? pill
        unloadAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .unloadAfterSeconds) ?? unloadAfterSeconds
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/talk/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else {
            let c = Config()
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(c).write(to: url)
            return c
        }
        guard let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    enum State { case idle, recording, transcribing }

    let config = Config.load()
    let engine = Engine()
    let recorder = Recorder()
    var hotkey: Hotkey?
    var item: NSStatusItem!
    var state = State.idle { didSet { refreshIcon() } }
    var pending = 0
    var unloadTask: Task<Void, Never>?
    lazy var hud = HUD(atTop: config.pill == "top")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshIcon()
        hotkey = Hotkey(spec: config.hotkey) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        buildMenu()
        _ = Paster.isTrusted(prompt: true)
        log("ready, hotkey \(config.hotkey), footprint \(Int(footprintMB())) MB")
        warmUpIfNewBuild()
    }

    /// After a rebuild, macOS recompiles the model for the Neural Engine (10-14 s per load for
    /// the first few loads). Pay that once in the background, then unload, so the first real
    /// dictation loads in ~0.2 s.
    func warmUpIfNewBuild() {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let key = "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attrs?[.size] ?? 0)"
        guard UserDefaults.standard.string(forKey: "warmedBuild") != key else { return }
        Task { @MainActor in
            for round in 1...5 {
                guard state == .idle, pending == 0 else { return }  // user is dictating: try next launch
                let t0 = Date()
                engine.prepare()
                do {
                    _ = try await engine.transcribe([Float](repeating: 0, count: 16000))
                } catch {
                    log("warm-up: \(error.localizedDescription)")
                    return
                }
                let took = ms(since: t0)
                guard state == .idle, pending == 0 else { return }
                await engine.unload()
                log("warm-up round \(round): \(took) ms")
                if took < 1500 {
                    UserDefaults.standard.set(key, forKey: "warmedBuild")
                    return
                }
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let title = hotkey == nil ? "Hotkey \(config.hotkey) unavailable — edit ~/.config/talk/config.json"
                                  : "Toggle dictation: \(config.hotkey)"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let cfg = NSMenuItem(title: "Open config…", action: #selector(openConfig), keyEquivalent: "")
        cfg.target = self
        menu.addItem(cfg)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Talk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("login item: \(error.localizedDescription)") }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func openConfig() { NSWorkspace.shared.open(Config.url) }

    func refreshIcon() {
        item?.button?.image = switch state {
        case .idle: Icon.menuBar(.wave)
        case .recording: Icon.menuBar(.wave, tint: .systemRed)
        case .transcribing: Icon.menuBar(.dots)
        }
    }

    func toggle() {
        if state == .recording { stopAndTranscribe() } else { startRecording() }
    }

    func startRecording() {
        unloadTask?.cancel()
        do { try recorder.start() } catch {
            log("mic: \(error.localizedDescription)")
            NSSound.beep()
            hud.finish(.error("Microphone unavailable"), after: 2)
            return
        }
        state = .recording
        NSSound(named: "Tink")?.play()
        recorder.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        engine.prepare()  // load the model while the user is talking; transcribe() waits for it
        hud.show(.listening)
    }

    func stopAndTranscribe() {
        let samples = recorder.stop()
        NSSound(named: "Pop")?.play()
        recorder.onLevel = nil
        guard samples.count > 16000 * 3 / 10 else {  // < 0.3 s: treat as a mistap
            state = .idle
            hud.hide()
            scheduleUnload()
            return
        }
        state = .transcribing
        hud.show(.transcribing)
        pending += 1
        Task { @MainActor in
            defer {
                pending -= 1
                if state == .transcribing && pending == 0 { state = .idle }
                scheduleUnload()
            }
            do {
                let text = try await engine.transcribe(samples)
                guard state != .recording else {  // a new dictation already started
                    if !text.isEmpty { Paster.paste(text + " ") }
                    return
                }
                if text.isEmpty {
                    hud.finish(.error("Nothing heard"), after: 1.2)
                } else if Paster.paste(text + " ") {
                    hud.finish(.done("Pasted"), after: 0.7)
                } else {
                    hud.finish(.error("Copied — press ⌘V (allow Accessibility)"), after: 2.5)
                }
            } catch {
                log("transcribe: \(error.localizedDescription)")
                NSSound.beep()
                if state != .recording { hud.finish(.error("Transcription failed"), after: 2) }
            }
        }
    }

    func scheduleUnload() {
        guard state == .idle, pending == 0 else { return }
        unloadTask?.cancel()
        let delay = config.unloadAfterSeconds
        unloadTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, state == .idle, pending == 0 else { return }
            await engine.unload()
            log("idle footprint \(Int(footprintMB())) MB")
        }
    }
}

// MARK: - entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    // Self-test: load → transcribe → unload, with timings and memory.
    let url = URL(fileURLWithPath: args[i + 1])
    Task { @MainActor in
        do {
            let samples = try Recorder.load(file: url)
            log("start footprint \(Int(footprintMB())) MB, \(samples.count) samples")
            let engine = Engine()
            let t0 = Date()
            let text = try await engine.transcribe(samples)
            log("first call total \(ms(since: t0)) ms, footprint \(Int(footprintMB())) MB")
            let t1 = Date()
            _ = try await engine.transcribe(samples)
            log("warm call \(ms(since: t1)) ms")
            await engine.unload()
            try? await Task.sleep(for: .seconds(1))
            log("after unload footprint \(Int(footprintMB())) MB")
            print(text)
            exit(0)
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--render-icons"), i + 1 < args.count {
    do { try Icon.render(to: URL(fileURLWithPath: args[i + 1])) } catch { log("icons: \(error)"); exit(1) }
} else if args.contains("--render-pill") {
    MainActor.assumeIsolated { HUD.renderPreviews(to: URL(fileURLWithPath: "/tmp")) }
} else if args.contains("--demo-pill") {
    // Visual check: cycles the pill through every state (screenshot it).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let hud = HUD(atTop: args.contains("--top"))
        let steps: [(Double, () -> Void)] = [
            (0, { hud.show(.loading) }),
            (2, { hud.show(.listening); hud.setLevel(0.6) }),
            (4, { hud.show(.transcribing) }),
            (6, { hud.finish(.done("Pasted"), after: 1.5) }),
            (8, { exit(0) }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }
    app.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { App() }
    app.delegate = delegate
    app.run()
}

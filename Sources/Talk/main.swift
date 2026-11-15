import AppKit

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, transcribing }

    private(set) var config = Config.load()
    let engine = ModelWorker()
    let recorder = Recorder()
    private var hotkey: Hotkey?
    /// True while Settings records a new shortcut; the old one is released meanwhile.
    private var hotkeySuspended = false
    var item: NSStatusItem?
    private var statusLine: NSMenuItem?
    var state = State.idle { didSet { refreshIcon() } }
    var pending = 0
    var unloadTask: Task<Void, Never>?
    lazy var hud = HUD(atTop: config.pill == "top")
    lazy var windows = Windows(app: self)
    /// Self-tests (`--check-gui`, `--measure-idle`) never claim the global hotkey, load the model or prompt.
    var selfTest = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshIcon()
        hotkey = makeHotkey(config.hotkey)
        buildMenu()
        engine.onDownloadChange = { [weak self] in self?.downloadChanged() }
        log("ready, hotkey \(config.hotkey), footprint \(Int(footprintMB())) MB")
        // First launch, or something dictation needs is missing: show the checklist.
        let needsSetup = setupNeeded
        guard !selfTest else { return }
        if needsSetup { showSetup() }
        warmUpIfNewBuild()
    }

    /// Clicking Talk in Finder while it already runs: there is no Dock icon, so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { if setupNeeded { showSetup() } else { showSettings() } }
        return false
    }

    // MARK: setup, settings

    var setupNeeded: Bool {
        Permissions.microphone != .granted || !Permissions.accessibility || !Engine.isDownloaded
            || Config.loadError != nil || !hotkeyAvailable
    }

    var hotkeyAvailable: Bool { hotkey != nil || hotkeySuspended || selfTest }

    private func makeHotkey(_ spec: String) -> Hotkey? {
        guard !selfTest else { return nil }
        return Hotkey(spec: spec) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }

    /// Applies new settings while Talk runs and saves them. Returns a sentence when something could
    /// not be applied (the shortcut is then left as it was).
    func apply(_ new: Config) -> String? {
        var new = new
        var problem: String?
        if new.hotkey != config.hotkey || hotkey == nil {
            hotkey = nil  // release the old combination before asking for the new one
            hotkeySuspended = false
            hotkey = makeHotkey(new.hotkey)
            if hotkey == nil && new.hotkey != config.hotkey && !selfTest {
                problem = "\(Hotkey.display(new.hotkey)) can't be used (another app may have taken it). Kept \(Hotkey.display(config.hotkey))."
                new.hotkey = config.hotkey
                hotkey = makeHotkey(config.hotkey)
            }
        }
        config = new
        hud.atTop = config.pill == "top"
        do { try config.save() } catch {
            problem = "Couldn't save config.json: \(error.localizedDescription)"
        }
        return problem
    }

    func suspendHotkey() {
        hotkey = nil
        hotkeySuspended = true
    }

    func resumeHotkey() {
        hotkeySuspended = false
        if hotkey == nil { hotkey = makeHotkey(config.hotkey) }
    }

    /// Reads config.json again (after the user repaired it by hand).
    func reloadConfig() {
        let loaded = Config.load()
        if Config.loadError == nil { _ = apply(loaded) }
    }

    /// Replaces an unreadable config.json with the defaults (the old file is kept as config.json.bak).
    func resetConfig() {
        do { _ = apply(try Config.resetToDefaults()) } catch {
            log("config reset: \(error.localizedDescription)")
        }
    }

    /// Fetches the model now (Setup's Download button), then releases it again.
    func downloadModel() {
        engine.prepare()
        Task { @MainActor in
            try? await engine.waitUntilLoaded()
            scheduleUnload()
        }
    }

    private func downloadChanged() {
        if let fraction = engine.downloadFraction { hud.setDownload(fraction) }
        windows.refresh()
    }

    @objc func showSetup() { windows.showSetup() }
    @objc func showSettings() { windows.showSettings() }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Dictation that stays on your Mac.\nSpeech model: Parakeet TDT v3, run with FluidAudio.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
        menu.delegate = self
        menu.autoenablesItems = false
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup…", action: #selector(showSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Talk", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Talk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item?.menu = menu
    }

    /// The status line is worked out when the menu opens, so nothing polls while it is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine?.title = statusText
    }

    var statusText: String {
        let shortcut = Hotkey.display(config.hotkey)
        if Config.loadError != nil { return "config.json can't be read: using defaults" }
        if Permissions.microphone != .granted { return "Setup needed: Microphone" }
        if !Permissions.accessibility { return "Setup needed: Accessibility" }
        if let fraction = engine.downloadFraction { return "Downloading speech model… \(Int(fraction * 100)) %" }
        if !Engine.isDownloaded { return "Setup needed: speech model" }
        if !hotkeyAvailable { return "Shortcut \(shortcut) is unavailable" }
        return switch state {
        case .idle: "Press \(shortcut) to dictate"
        case .recording: "Listening: press \(shortcut) to finish"
        case .transcribing: "Transcribing…"
        }
    }

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
        // Without microphone access macOS hands over silence, which would end as "Nothing heard".
        switch Permissions.microphone {
        case .granted:
            break
        case .notAsked:
            Permissions.requestMicrophone { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.hud.finish(.done("Microphone ready: press \(Hotkey.display(self.config.hotkey)) again"), after: 2)
                    self.windows.refresh()
                } else {
                    self.showSetup()
                }
            }
            return
        case .denied:
            NSSound.beep()
            hud.finish(.error("Microphone access is off: see Talk Setup"), after: 2.5)
            showSetup()
            return
        }
        // First run: the model is still on its way. Show how far it is instead of recording into a long wait.
        guard Engine.isDownloaded else {
            downloadModel()
            hud.finish(.downloading(engine.downloadFraction ?? 0), after: 3)
            showSetup()
            return
        }
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
        hud.show(engine.isReady ? .transcribing : .loading)
        pending += 1
        Task { @MainActor in
            defer {
                pending -= 1
                if state == .transcribing && pending == 0 { state = .idle }
                scheduleUnload()
            }
            do {
                if !engine.isReady {  // short dictation or first load after an update: the model is still loading
                    try? await engine.waitUntilLoaded()
                    if state != .recording { hud.show(.transcribing) }
                }
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
                    hud.finish(.error("Copied: press ⌘V (Accessibility is off)"), after: 3)
                    showSetup()
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
signal(SIGPIPE, SIG_IGN)  // a model worker that exits early must not take the app down with it
if args.count > 1 && args[1] == "--model-worker" {
    WorkerMain.run()
} else if let i = args.firstIndex(of: "--worker-test"), i + 1 < args.count {
    MainActor.assumeIsolated { SelfTest.workerTest(files: args[(i + 1)...].map { URL(fileURLWithPath: $0) }) }
    RunLoop.main.run()
} else if args.count > 1 && args[1] == "transcribe" {
    TranscribeCLI.run(Array(args.dropFirst(2)))
} else if args.count > 1 && ["help", "-h", "--help"].contains(args[1]) {
    print("Talk: menu-bar dictation. Run with no arguments to start the app.\n\n" + TranscribeCLI.usage)
} else if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
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
} else if let i = args.firstIndex(of: "--check-gui"), i + 1 < args.count {
    MainActor.assumeIsolated { SelfTest.checkGUI(renderTo: URL(fileURLWithPath: args[i + 1])) }
} else if args.contains("--measure-idle") {
    MainActor.assumeIsolated { SelfTest.measureIdle() }
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

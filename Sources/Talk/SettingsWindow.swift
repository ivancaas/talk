import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var configError: String?
    /// True while the shortcut field waits for a key press.
    @Published var recording = false
    @Published var hotkeyNote: String?
    @Published var launchAtLogin = false
    @Published var loginNote: String?
    @Published var memoryMB = 0
    @Published var modelLoaded = false

    let app: App
    private var timer: Timer?
    private var keyMonitor: Any?

    init(app: App) {
        self.app = app
        config = app.config
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Live values: memory, model in memory or not, login item, and the config as Talk is using it.
    func refresh() {
        set(\.memoryMB, Int(footprintMB().rounded()))
        set(\.modelLoaded, app.engine.isReady)
        set(\.launchAtLogin, SMAppService.mainApp.status == .enabled)
        set(\.configError, Config.loadError)
        set(\.config, app.config)
        if !app.hotkeyAvailable && !recording && hotkeyNote == nil {
            hotkeyNote = "\(Hotkey.display(config.hotkey)) can't be used. Another app may have taken it."
        }
    }

    private func set<T: Equatable>(_ path: ReferenceWritableKeyPath<SettingsModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    /// Called when the window closes: nothing keeps running.
    func stop() {
        cancelRecording()
        timer?.invalidate()
        timer = nil
    }

    /// Changes one setting: Talk applies it at once and saves config.json.
    func change(_ edit: (inout Config) -> Void) {
        var next = app.config
        edit(&next)
        guard next != app.config else { return }
        hotkeyNote = app.apply(next)
        config = app.config
    }

    // MARK: shortcut recorder

    func toggleRecording() {
        if recording { cancelRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        recording = true
        hotkeyNote = nil
        app.suspendHotkey()  // so the current shortcut can be pressed again without starting a dictation
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {  // plain Escape
            cancelRecording()
        } else if let spec = Hotkey.spec(keyCode: event.keyCode, modifiers: modifiers) {
            endRecording()
            change { $0.hotkey = spec }
            app.resumeHotkey()
        } else {
            NSSound.beep()
            hotkeyNote = "Hold ⌘, ⌥ or ⌃ and press a letter, number, Space or F-key. Esc cancels."
        }
    }

    func cancelRecording() {
        guard recording else { return }
        endRecording()
        hotkeyNote = nil
        app.resumeHotkey()
    }

    private func endRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = false
    }

    // MARK: login item, config file

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            loginNote = "Allow Talk under System Settings › General › Login Items."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openConfigFile() { NSWorkspace.shared.open(Config.url) }
    func revealConfigFile() { NSWorkspace.shared.activateFileViewerSelecting([Config.url]) }

    func reloadConfig() {
        app.reloadConfig()
        refresh()
    }

    func useDefaults() {
        app.resetConfig()
        refresh()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if let error = model.configError {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("config.json can't be read").font(.headline)
                            Text("\(error). Talk is using its defaults and has left the file as it is.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Open File", action: model.openConfigFile)
                        Button("Reload", action: model.reloadConfig)
                        Spacer()
                        Button("Use Defaults", action: model.useDefaults)
                            .help("Keeps the old file as config.json.bak")
                    }
                }
            }

            Section {
                LabeledContent("Dictation shortcut") {
                    Button(action: model.toggleRecording) {
                        Text(model.recording ? "Press shortcut…" : Hotkey.display(model.config.hotkey))
                            .frame(minWidth: 110)
                    }
                    .help("Click, then press the keys you want")
                }
                if let note = model.hotkeyNote {
                    Text(note).font(.subheadline).foregroundStyle(.orange)
                }
                Picker("Status pill", selection: pill) {
                    Text("Bottom of the screen").tag("bottom")
                    Text("Top of the screen").tag("top")
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                if let note = model.loginNote {
                    Text(note).font(.subheadline).foregroundStyle(.orange)
                }
            }
            .disabled(model.configError != nil)

            Section {
                LabeledContent("Memory in use now") {
                    Text("\(model.memoryMB) MB").monospacedDigit()
                }
                LabeledContent("Speech model") {
                    Text(model.modelLoaded ? "In memory" : "Not loaded")
                }
                LabeledContent("Keep the model loaded after dictating") {
                    HStack(spacing: 6) {
                        TextField("Seconds", value: keepWarm, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                        Text("s")
                        Stepper("Seconds", value: keepWarm, in: 0...3600, step: 10).labelsHidden()
                    }
                }
                .disabled(model.configError != nil)
            } header: {
                Text("Lightweight by design")
            } footer: {
                Text("The speech model is loaded when you start dictating and released when the text is pasted, so Talk stays small while idle. With 0 s it is released at once; a longer time makes the next dictation start faster. This window adds a little memory of its own while it is open.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Settings file") {
                    HStack(spacing: 8) {
                        Text("~/.config/talk/config.json").foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Show in Finder", action: model.revealConfigFile)
                    }
                }
            } footer: {
                Text("Changes apply right away.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pill: Binding<String> {
        Binding(get: { model.config.pill == "top" ? "top" : "bottom" },
                set: { value in model.change { $0.pill = value } })
    }

    private var keepWarm: Binding<Double> {
        Binding(get: { model.config.unloadAfterSeconds },
                set: { value in model.change { $0.unloadAfterSeconds = min(3600, max(0, value.rounded())) } })
    }
}

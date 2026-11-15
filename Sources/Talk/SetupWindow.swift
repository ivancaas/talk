import AppKit
import SwiftUI

/// Everything the Setup window shows, read fresh once a second while the window is open.
struct SetupState: Equatable {
    enum SpeechModel: Equatable { case missing, downloading(Double), failed(String), ready }

    var microphone = Permissions.Microphone.granted
    var accessibility = true
    var speechModel = SpeechModel.ready
    /// Set when config.json could not be read.
    var configError: String?
    /// The shortcut as shown ("⌥Space") and whether macOS let Talk register it.
    var hotkey = ""
    var hotkeyAvailable = true

    /// The three things dictation cannot work without.
    var readyCount: Int {
        (microphone == .granted ? 1 : 0) + (accessibility ? 1 : 0) + (speechModel == .ready ? 1 : 0)
    }
    var allReady: Bool { readyCount == 3 && configError == nil && hotkeyAvailable }

    @MainActor static func current(_ app: App) -> SetupState {
        var s = SetupState()
        s.microphone = Permissions.microphone
        s.accessibility = Permissions.accessibility
        if let fraction = app.engine.downloadFraction {
            s.speechModel = .downloading(fraction)
        } else if Engine.isDownloaded {
            s.speechModel = .ready
        } else if let error = app.engine.lastError {
            s.speechModel = .failed(error)
        } else {
            s.speechModel = .missing
        }
        s.configError = Config.loadError
        s.hotkey = Hotkey.display(app.config.hotkey)
        s.hotkeyAvailable = app.hotkeyAvailable
        return s
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var state: SetupState
    /// True after the Accessibility prompt was shown once from this window; the button then opens System Settings.
    @Published var askedAccessibility = false
    let app: App
    var close: () -> Void = {}
    /// Talk's own icon, drawn here so it is right even when Talk runs outside its app bundle.
    let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
        Icon.drawAppIcon(px: 64)
        return true
    }
    private var timer: Timer?

    init(app: App) {
        self.app = app
        state = .current(app)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let now = SetupState.current(app)
        if now != state { state = now }
    }

    /// Called when the window closes: nothing keeps running.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func grantMicrophone() {
        if state.microphone == .notAsked {
            Permissions.requestMicrophone { [weak self] _ in self?.refresh() }
        } else {
            Permissions.openSystemSettings(.microphone)
        }
    }

    func grantAccessibility() {
        if askedAccessibility {
            Permissions.openSystemSettings(.accessibility)
        } else {
            askedAccessibility = true
            Permissions.requestAccessibility()
        }
    }

    func downloadModel() {
        app.downloadModel()
        refresh()
    }

    func openSettings() { app.showSettings() }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: model.icon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Up Talk").font(.title2.weight(.semibold))
                    Text("Press \(s.hotkey), speak, press \(s.hotkey) again. Your voice is transcribed on this Mac and never leaves it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            VStack(spacing: 0) {
                SetupRow(symbol: "mic.fill", title: "Microphone", detail: microphoneDetail(s), ready: s.microphone == .granted) {
                    Button(s.microphone == .notAsked ? "Allow…" : "Open System Settings…", action: model.grantMicrophone)
                }
                Divider()
                SetupRow(symbol: "accessibility", title: "Accessibility", detail: accessibilityDetail(s), ready: s.accessibility) {
                    Button(model.askedAccessibility ? "Open System Settings…" : "Grant…", action: model.grantAccessibility)
                }
                Divider()
                SetupRow(symbol: "waveform", title: "Speech model", detail: modelDetail(s), ready: s.speechModel == .ready) {
                    switch s.speechModel {
                    case .downloading(let fraction):
                        HStack(spacing: 8) {
                            ProgressView(value: fraction).frame(width: 110)
                            Text("\(Int(fraction * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                        }
                    case .failed:
                        Button("Try Again", action: model.downloadModel)
                    default:
                        Button("Download", action: model.downloadModel)
                    }
                }
                if let error = s.configError {
                    Divider()
                    SetupRow(symbol: "doc.badge.gearshape", title: "Settings file",
                             detail: "config.json can't be read, so Talk is using its defaults. \(error).", ready: false, warning: true) {
                        Button("Open Settings…", action: model.openSettings)
                    }
                }
                if !s.hotkeyAvailable {
                    Divider()
                    SetupRow(symbol: "keyboard", title: "Shortcut",
                             detail: "\(s.hotkey) can't be used. Another app may have taken it.", ready: false, warning: true) {
                        Button("Change…", action: model.openSettings)
                    }
                }
            }
            .padding(.horizontal, 20)

            Divider()

            HStack {
                Text(s.allReady ? "All set. Talk lives in the menu bar." : "\(s.readyCount) of 3 ready. This list updates by itself.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func microphoneDetail(_ s: SetupState) -> String {
        switch s.microphone {
        case .denied: "Access is turned off. Turn Talk on under Privacy & Security › Microphone."
        default: "To hear you. The microphone is open only while you dictate."
        }
    }

    private func accessibilityDetail(_ s: SetupState) -> String {
        if !s.accessibility && model.askedAccessibility {
            return "Turn Talk on in Privacy & Security › Accessibility. If this stays unticked, quit and reopen Talk."
        }
        return "To paste the text into the app you are typing in."
    }

    private func modelDetail(_ s: SetupState) -> String {
        switch s.speechModel {
        case .ready: "Parakeet v3, stored on this Mac. Loaded only while you dictate."
        case .downloading: "Downloading about 600 MB, once. You can close this window."
        case .failed(let error): "The download did not finish: \(error)"
        case .missing: "Parakeet v3, about 600 MB, downloaded once."
        }
    }
}

/// One checklist line: symbol, what it is for, and either a green check or the control that fixes it.
private struct SetupRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let ready: Bool
    var warning = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ready {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Ready")
            } else {
                control()
            }
        }
        .padding(.vertical, 12)
    }
}

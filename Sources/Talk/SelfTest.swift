import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Checks for the Setup and Settings windows that run without Xcode or a test target:
///   Talk --check-gui <folder>   logic checks + a PNG of each window state, light and dark
///   Talk --measure-idle         memory before the windows open, while open, and after they close
/// Neither claims the global hotkey, loads the model or asks for a permission.
@MainActor
enum SelfTest {
    private static var pass = 0
    private static var fail = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { pass += 1 } else { fail += 1 }
        print("\(ok ? "PASS" : "FAIL"): \(name)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    static func checkGUI(renderTo dir: URL) {
        _ = NSApplication.shared

        // Shortcut text, both ways.
        check("display opt+space", Hotkey.display("opt+space") == "⌥Space", Hotkey.display("opt+space"))
        check("display ctrl+opt+d", Hotkey.display("ctrl+opt+d") == "⌃⌥D", Hotkey.display("ctrl+opt+d"))
        check("display cmd+shift+f5", Hotkey.display("cmd+shift+f5") == "⇧⌘F5", Hotkey.display("cmd+shift+f5"))
        check("display f13", Hotkey.display("f13") == "F13")
        check("record ⌥Space", Hotkey.spec(keyCode: UInt16(kVK_Space), modifiers: .option) == "opt+space")
        check("record plain letter refused", Hotkey.spec(keyCode: 0, modifiers: []) == nil)
        check("record ⇧letter refused", Hotkey.spec(keyCode: 0, modifiers: .shift) == nil)
        check("record bare F13", Hotkey.spec(keyCode: 0x69, modifiers: []) == "f13")
        check("record unknown key refused", Hotkey.spec(keyCode: UInt16(kVK_UpArrow), modifiers: .command) == nil)
        let allMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let carbonAll = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let broken = Hotkey.keyCodes.filter { name, code in
            guard let spec = Hotkey.spec(keyCode: UInt16(code), modifiers: allMods),
                  let parsed = Hotkey.parse(spec) else { return true }
            return parsed.0 != code || parsed.1 != carbonAll
        }
        check("every recordable key parses back", broken.isEmpty, "\(Hotkey.keyCodes.count) keys, broken: \(broken.keys.sorted())")

        // Config errors are reported, not swallowed.
        check("config {} gives defaults", (try? Config.decode(Data("{}".utf8))) == Config())
        func message(_ json: String) -> String {
            do { _ = try Config.decode(Data(json.utf8)); return "" } catch { return Config.describe(error) }
        }
        check("config wrong type names the key", message(#"{"hotkey": 5}"#).contains("hotkey"), message(#"{"hotkey": 5}"#))
        check("config broken JSON is reported", message("{ nope").hasPrefix("Not valid JSON"), message("{ nope"))
        check("config array is reported", !message("[1]").isEmpty, message("[1]"))

        // Checklist logic.
        var s = SetupState()
        check("setup all ready", s.allReady && s.readyCount == 3)
        s.microphone = .denied
        s.speechModel = .downloading(0.4)
        check("setup counts missing items", !s.allReady && s.readyCount == 1)

        let t0 = Date()
        let onDisk = Engine.isDownloaded
        print("INFO: model on disk = \(onDisk) (checked in \(ms(since: t0)) ms), microphone = \(Permissions.microphone), accessibility = \(Permissions.accessibility)")

        // Pictures of each window state.
        let app = App()
        app.selfTest = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var ready = SetupState()
        ready.hotkey = "⌥Space"
        var first = ready
        first.microphone = .notAsked
        first.accessibility = false
        first.speechModel = .downloading(0.42)
        var trouble = ready
        trouble.microphone = .denied
        trouble.speechModel = .failed("The Internet connection appears to be offline.")
        trouble.configError = "Not valid JSON: Unexpected character 'n' around line 1, column 3"
        trouble.hotkeyAvailable = false
        for (name, state) in [("setup-ready", ready), ("setup-first-run", first), ("setup-trouble", trouble)] {
            let model = SetupModel(app: app)
            model.stop()
            model.state = state
            render(SetupView(model: model), name, dir)
        }

        let settings = SettingsModel(app: app)
        settings.stop()
        render(SettingsView(model: settings), "settings", dir)
        settings.configError = "“hotkey” has the wrong type"
        settings.recording = true
        render(SettingsView(model: settings), "settings-invalid-config", dir)

        print("RESULT pass=\(pass) fail=\(fail)")
        exit(fail == 0 ? 0 : 1)
    }

    private static func render<Content: View>(_ view: Content, _ name: String, _ dir: URL) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = name.hasPrefix("setup") ? "Talk Setup" : "Talk Settings"
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(host.view.fittingSize)
            window.layoutIfNeeded()
            guard let content = window.contentView?.superview ?? window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                check("render \(name)-\(suffix)", false)
                continue
            }
            content.cacheDisplay(in: content.bounds, to: rep)
            let url = dir.appendingPathComponent("\(name)-\(suffix).png")
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
            check("render \(name)-\(suffix)", ok && content.bounds.height > 100, "\(Int(content.bounds.width)) x \(Int(content.bounds.height)) pt")
            window.contentViewController = nil
        }
    }

    /// Runs the menu-bar app for a few seconds without its hotkey: footprint after launch, after the status
    /// pill was shown once, with both windows open, and after closing them (models and timers must be gone).
    static func measureIdle() {
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.accessory)
        let app = App()
        app.selfTest = true
        nsApp.delegate = app
        func report(_ label: String) {
            print("INFO: \(label): footprint \(String(format: "%.1f", footprintMB())) MB, resident \(String(format: "%.1f", residentMB())) MB")
        }
        weak var setupModel: SetupModel?
        weak var settingsModel: SettingsModel?
        weak var setupWindow: NSWindow?
        let steps: [(Double, @MainActor @Sendable () -> Void)] = [
            (2, {
                report("idle after launch")
                app.hud.finish(.done("Self-test"), after: 1)  // what every dictation shows
            }),
            (6, {
                report("idle after the status pill was shown once")
                app.showSetup()
                app.showSettings()
                setupModel = app.windows.setup?.model
                settingsModel = app.windows.settings?.model
                setupWindow = app.windows.setup?.window
            }),
            (10, {
                report("Setup and Settings open")
                check("both windows opened", setupModel != nil && settingsModel != nil)
                app.windows.setup?.window.close()
                app.windows.settings?.window.close()
            }),
            (16, {
                report("idle again, windows closed")
                check("window models released", setupModel == nil && settingsModel == nil)
                check("window released", setupWindow == nil)
                print("RESULT pass=\(pass) fail=\(fail)")
                exit(fail == 0 ? 0 : 1)
            }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        nsApp.run()
    }
}

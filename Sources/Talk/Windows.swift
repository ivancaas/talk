import AppKit
import SwiftUI

/// Setup and Settings windows. Each is built when asked for and dropped (view, model, timer) when
/// closed, so an idle Talk holds no window and runs no timer.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    private unowned let app: App
    private(set) var setup: (window: NSWindow, model: SetupModel)?
    private(set) var settings: (window: NSWindow, model: SettingsModel)?

    init(app: App) { self.app = app }

    func showSetup() {
        if setup == nil {
            let model = SetupModel(app: app)
            let window = makeWindow(title: "Talk Setup", SetupView(model: model))
            model.close = { [weak window] in window?.close() }
            setup = (window, model)
        }
        present(setup!.window)
    }

    func showSettings() {
        if settings == nil {
            let model = SettingsModel(app: app)
            settings = (makeWindow(title: "Talk Settings", SettingsView(model: model)), model)
        }
        present(settings!.window)
    }

    /// Something changed outside the one-second poll (download progress, a setting): redraw now.
    func refresh() {
        setup?.model.refresh()
        settings?.model.refresh()
    }

    private func makeWindow<Content: View>(title: String, _ view: Content) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(host.view.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        installMainMenu()
        guard !app.selfTest else { return window.orderFrontRegardless() }  // a self-test must not take focus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === settings?.window { settings?.model.cancelRecording() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === setup?.window {
            setup?.model.stop()
            setup = nil
        } else if window === settings?.window {
            settings?.model.stop()
            settings = nil
        }
        window.delegate = nil
        // Let AppKit finish closing, then free the SwiftUI view tree.
        DispatchQueue.main.async { window.contentViewController = nil }
    }

    /// Talk has no menu bar of its own (it is a menu-bar extra), but an installed main menu is what
    /// makes ⌘, ⌘W, ⌘Q and copy/paste work while one of its windows is in front.
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Talk", action: #selector(App.showAbout), keyEquivalent: "").target = app
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(App.showSettings), keyEquivalent: ",").target = app
        appMenu.addItem(withTitle: "Setup…", action: #selector(App.showSetup), keyEquivalent: "").target = app
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Talk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Talk", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        NSApp.mainMenu = main
    }
}

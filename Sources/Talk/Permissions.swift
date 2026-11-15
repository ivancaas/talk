import AVFAudio
import AppKit
import ApplicationServices

/// What Talk needs from macOS: the microphone to hear, Accessibility to paste.
enum Permissions {
    enum Microphone { case granted, notAsked, denied }

    static var microphone: Microphone {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .notAsked
        default: .denied
        }
    }

    /// Shows the system prompt (macOS only shows it while the permission was never asked).
    static func requestMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in done(ok) }
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Adds Talk to the Accessibility list and shows the system prompt. Only Setup calls this.
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    enum Pane: String { case microphone = "Privacy_Microphone", accessibility = "Privacy_Accessibility" }

    static func openSystemSettings(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}

import Carbon.HIToolbox
import Foundation

/// Global hotkey through Carbon (no Accessibility permission needed for the key itself).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    /// spec like "opt+space", "ctrl+opt+d", "cmd+shift+f5", "f13"
    init?(spec: String, onPress: @escaping () -> Void) {
        guard let (key, mods) = Hotkey.parse(spec) else { return nil }
        Hotkey.handler = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.handler?()
            return noErr
        }, 1, &type, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x54414C4B), id: 1)  // 'TALK'
        let status = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { log("hotkey \(spec) could not be registered (\(status)); is another app using it?"); return nil }
    }

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default:
                // One key, and it must be known: a typo like "optn+space" must not register bare Space.
                guard key == nil, let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab),
            "escape": UInt32(kVK_Escape), "`": UInt32(kVK_ANSI_Grave), ";": UInt32(kVK_ANSI_Semicolon),
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
            "n": 0x2D, "m": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C,
            "9": 0x19, "0": 0x1D,
        ]
        let f: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                           0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, code) in f.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()
}

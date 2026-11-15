import AppKit

/// Text forms of a hotkey for the Settings recorder: what is shown ("⌥Space") and what is saved ("opt+space").
extension Hotkey {
    /// "ctrl+opt+d" → "⌃⌥D". Unknown parts are shown as written.
    static func display(_ spec: String) -> String {
        var mods = Set<String>()
        var key = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods.insert("⌘")
            case "opt", "option", "alt": mods.insert("⌥")
            case "ctrl", "control": mods.insert("⌃")
            case "shift": mods.insert("⇧")
            default: key = part
            }
        }
        let name: String = switch key {
        case "space": "Space"
        case "return": "↩"
        case "tab": "⇥"
        case "escape": "⎋"
        default: key.uppercased()
        }
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + name
    }

    /// The config spec for a key press, or nil when Talk can't use it: an unknown key, or a plain key
    /// without ⌘, ⌥ or ⌃ (function keys may stand alone).
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        let isFunctionKey = key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
        guard isFunctionKey || !modifiers.intersection([.control, .option, .command]).isEmpty else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
}

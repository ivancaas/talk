import AppKit
import ApplicationServices

/// Puts text into the focused app: clipboard + synthetic ⌘V, then restores the previous clipboard.
enum Paster {
    /// Returns false when Accessibility is missing (text is left on the clipboard). Never prompts:
    /// the caller sends the user to Setup, the one place that asks for the permission.
    @MainActor @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard Permissions.accessibility else {
            log("no Accessibility permission: text left on the clipboard")
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        let changeCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pb.changeCount == changeCount, !saved.isEmpty else { return }
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            }
            pb.writeObjects(items)
        }
        return true
    }
}

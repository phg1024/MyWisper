import AppKit
import ApplicationServices

/// Puts text at the cursor of whatever app has focus: clipboard + a synthetic ⌘V,
/// then (optionally) puts the previous clipboard back.
enum TextInjector {
    /// Tags our synthetic key events so the hotkey monitor ignores them.
    static let eventMarker: Int64 = 0x4D_5769_7370   // "MWisp"

    /// Returns false when Accessibility is missing; the text is then only on the clipboard.
    @discardableResult
    static func paste(_ text: String, restoreClipboard: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pasteboard) : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if restoreClipboard {
            // Clipboard managers skip transient items, so the dictated text doesn't pile up there.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        let ourChange = pasteboard.changeCount

        guard AXIsProcessTrusted() else { return false }
        postCommandV()

        if let saved {
            // Give slow apps (Electron, terminals) time to read the clipboard before it changes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pasteboard.changeCount == ourChange else { return }   // the user copied something meanwhile
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down) else { continue }
            event.flags = .maskCommand   // explicit, so a still-held dictation key doesn't turn this into ⌥⌘V
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

import AppKit
import ApplicationServices

/// Puts text at the cursor of whatever app has focus: clipboard + a synthetic ⌘V,
/// then (optionally) puts the previous clipboard back.
enum TextInjector {
    /// Tags our synthetic key events so the hotkey monitor ignores them.
    static let eventMarker: Int64 = 0x4D_5769_7370   // "MWisp"

    /// Returns false when Accessibility is missing; nothing is changed then.
    @MainActor @discardableResult
    static func paste(_ text: String, restoreClipboard: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // Slow apps (Electron, terminals) need a moment to read the clipboard before it changes back.
        ClipboardSwap.general.put(text, restoreAfter: restoreClipboard ? 0.6 : nil)
        postCommandV()
        return true
    }

    @MainActor
    static func copy(_ text: String) {
        ClipboardSwap.general.put(text, restoreAfter: nil)
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

/// Puts dictated text on the clipboard for a paste and, if asked, the user's own clipboard back after it.
@MainActor
final class ClipboardSwap {
    static let general = ClipboardSwap(.general)

    private let pasteboard: NSPasteboard
    /// The user's clipboard while putting it back is pending. A second paste in that time keeps this
    /// one rather than saving the first dictation as the user's.
    private var saved: [NSPasteboardItem]?
    /// The clipboard's change count right after our last write.
    private var ours = 0
    private var generation = 0

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func put(_ text: String, restoreAfter delay: TimeInterval?) {
        generation += 1
        if delay == nil {
            saved = nil
        } else if saved == nil || pasteboard.changeCount != ours {
            saved = snapshot()
        }
        // Like clearContents(), but what comes next stays on this Mac: Universal Clipboard does not
        // hand it to the user's iPhone or other Macs.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        if delay != nil {
            // Clipboard managers skip transient items, so the dictated text doesn't pile up there.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        ours = pasteboard.changeCount
        guard let delay else { return }
        let this = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard this == generation, let saved else { return }   // a later paste puts it back
            self.saved = nil
            guard pasteboard.changeCount == ours else { return }   // the user copied something meanwhile
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}

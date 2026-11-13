import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.peihongguo.MyWisper", category: "learning")

/// After a paste, watches the text field it went into for a little while. If the user fixes words in
/// what was just typed, reports the typed and fixed text. Reads only the focused field, through
/// Accessibility; apps that don't expose their text (many web and Electron apps) are simply skipped.
@MainActor
final class EditWatcher {
    static let shared = EditWatcher()
    static let watchFor: TimeInterval = 120

    private struct Watch {
        let element: AXUIElement
        let typed: String
        let before: String
        let after: String
        let started: Date
        let onEdit: (String) -> Void
        /// The user's version, once it has stayed the same for two polls; half-typed words never get here.
        var latest: String
        var candidate: String
    }

    private var watch: Watch?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    /// Call right after pasting `typed`. `onEdit` gets the user's version of it, once they are done.
    func begin(typed: String, onEdit: @escaping (String) -> Void) {
        finish()
        // Let the target app handle ⌘V first.
        let work = DispatchWorkItem { [weak self] in self?.attach(typed: typed, onEdit: onEdit) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Ends the current watch and reports an edit, if there was one.
    func finish() {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        guard let watch else { return }
        self.watch = nil
        log.notice("watch ended, edited: \(watch.latest != watch.typed)")
        if watch.latest != watch.typed { watch.onEdit(watch.latest) }
    }

    private func attach(typed: String, onEdit: @escaping (String) -> Void) {
        pending = nil
        guard let element = focusedElement(), !isSecure(element),
              let value = stringValue(of: element), value.utf16.count < 100_000 else {
            log.notice("no readable text field has focus")
            return
        }
        // The caret sits right after what we pasted; fall back to the last place the text appears.
        let utf16 = value.utf16
        var range: Range<String.Index>?
        if let caret = selectedRange(of: element), caret.location >= typed.utf16.count, caret.location <= utf16.count {
            let e = utf16.index(utf16.startIndex, offsetBy: caret.location)
            let s = utf16.index(e, offsetBy: -typed.utf16.count)
            if value[s..<e] == typed { range = s..<e }
        }
        guard let range = range ?? value.range(of: typed, options: .backwards) else {
            log.notice("pasted text not found in the focused field")
            return
        }
        log.notice("watching the focused field")
        watch = Watch(element: element, typed: typed, before: String(value[..<range.lowerBound]), after: String(value[range.upperBound...]),
                      started: Date(), onEdit: onEdit, latest: typed, candidate: typed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard var watch else { return }
        guard Date().timeIntervalSince(watch.started) < Self.watchFor,
              let focused = focusedElement(), CFEqual(focused, watch.element),
              let value = stringValue(of: watch.element) else { return finish() }
        // The text around ours is unchanged, so what's between is the user's version of ours.
        guard value.count >= watch.before.count + watch.after.count,
              value.hasPrefix(watch.before), value.hasSuffix(watch.after) else { return finish() }
        let middle = String(value.dropFirst(watch.before.count).dropLast(watch.after.count))
        // Gone altogether: sent (chat boxes empty themselves) or deleted. Keep the last version seen.
        guard !middle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return finish() }
        if middle == watch.candidate { watch.latest = middle } else { watch.candidate = middle }
        self.watch = watch
    }

    private func focusedElement() -> AXUIElement? {
        // Electron apps (Slack, VS Code, Claude...) only build their accessibility tree when asked.
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}

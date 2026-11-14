import CoreGraphics
import Foundation

/// Watches one modifier key system-wide through a Quartz event tap on the main run loop,
/// so every callback arrives on the main thread. Events pass through untouched, except an esc that
/// cancelled a recording: it was meant for MyWisper, not for the app in front (Vim, a dialog).
final class HotkeyMonitor {
    var hotkey: Hotkey { didSet { isDown = false } }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Another key, modifier or click while the hotkey is held: the user is typing a shortcut.
    var onChord: (() -> Void)?
    /// Returns true when the esc cancelled something; it then goes no further.
    var onEscape: (() -> Bool)?
    /// While set, sees every key event first; returning true swallows it for the dictation logic.
    var onCapture: ((CGEventType, Int64, CGEventFlags) -> Bool)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    /// Needs Accessibility: without it macOS still creates the tap but only feeds it our own app's events.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: me)
        guard let created else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
        isDown = false
    }

    /// Returns true to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.eventMarker { return false }   // our own ⌘V
        if let onCapture, type == .flagsChanged || type == .keyDown,
           onCapture(type, event.getIntegerValueField(.keyboardEventKeycode), event.flags) { return false }

        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == hotkey.keyCode {
                let down = hotkey.isHeld(in: event.flags)
                guard down != isDown else { return false }
                isDown = down
                down ? onDown?() : onUp?()
            } else if isDown {
                onChord?()
            }
        case .keyDown:
            let cancelled = event.getIntegerValueField(.keyboardEventKeycode) == 53 && onEscape?() == true
            if isDown { onChord?() }
            return cancelled
        case .leftMouseDown, .rightMouseDown:
            if isDown { onChord?() }
        default:
            break
        }
        return false
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo, Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

import CoreGraphics
import Foundation

/// Watches one modifier key system-wide through a Quartz event tap on the main run loop,
/// so every callback arrives on the main thread. Events are always passed through untouched.
final class HotkeyMonitor {
    var hotkey: Hotkey { didSet { isDown = false } }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Another key, modifier or click while the hotkey is held: the user is typing a shortcut.
    var onChord: (() -> Void)?
    var onEscape: (() -> Void)?
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

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.eventMarker { return }   // our own ⌘V
        if let onCapture, type == .flagsChanged || type == .keyDown,
           onCapture(type, event.getIntegerValueField(.keyboardEventKeycode), event.flags) { return }

        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == hotkey.keyCode {
                let down = hotkey.isHeld(in: event.flags)
                guard down != isDown else { return }
                isDown = down
                down ? onDown?() : onUp?()
            } else if isDown {
                onChord?()
            }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEscape?() }
            if isDown { onChord?() }
        case .leftMouseDown, .rightMouseDown:
            if isDown { onChord?() }
        default:
            break
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

import CoreGraphics
import Foundation
import Testing
@testable import MyWisper

struct RepeatedEndingTests {
    @Test func dropsARepeatedEnding() {
        #expect(RepeatedEnding.fix("this is pendingending") == "this is pending")
        #expect(RepeatedEnding.fix("an objectject here") == "an object here")
        #expect(RepeatedEnding.fix("visualualization") == "visualization")
    }

    @Test func leavesRealWordsAndNamesAlone() {
        #expect(RepeatedEnding.fix("singing and dancing") == "singing and dancing")
        #expect(RepeatedEnding.fix("Mississippi") == "Mississippi")
        #expect(RepeatedEnding.fix("用ender打印") == "用ender打印")
    }
}

struct HotkeyTests {
    let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)

    @Test func tellsTheSidesApart() {
        #expect(Hotkey.rightOption.isHeld(in: rightOption))
        #expect(!Hotkey.rightOption.isHeld(in: leftOption))
        #expect(Hotkey.leftOption.isHeld(in: leftOption))
        #expect(!Hotkey.rightCommand.isHeld(in: rightOption))
    }

    @Test func keyboardsWithoutSidesCountEitherKey() {
        #expect(Hotkey.rightOption.isHeld(in: .maskAlternate))
        #expect(Hotkey.leftOption.isHeld(in: .maskAlternate))
        #expect(!Hotkey.rightOption.isHeld(in: []))
    }

    @Test func fn() {
        #expect(Hotkey.fn.isHeld(in: .maskSecondaryFn))
        #expect(!Hotkey.fn.isHeld(in: rightOption))
    }

    @Test func keyCodesRoundTrip() {
        for key in Hotkey.allCases { #expect(Hotkey(keyCode: key.keyCode) == key) }
        #expect(Hotkey(keyCode: 0) == nil)
    }
}

struct AudioFileTests {
    @Test func wavHeader() {
        let data = AudioFile.wav([0, 0.5, -0.5, 2])
        #expect(data.count == 44 + 4 * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: UInt16(data[at]) | UInt16(data[at + 1]) << 8) }
        #expect(u32(4) == 36 + 8)
        #expect(u32(24) == 16000)
        #expect(u32(40) == 8)
        #expect([i16(44), i16(46), i16(48), i16(50)] == [0, 16383, -16383, Int16.max])   // 2 is clipped
    }

    @Test func wavReadsBack() throws {
        let samples = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFile.wav(samples).write(to: url)
        let back = try AudioFile.load16kMono(url)
        #expect(back.count == samples.count)
        #expect(zip(samples, back).allSatisfy { abs($0 - $1) < 1e-3 })
    }
}

struct HotkeyMonitorTests {
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return event
    }

    @Test func escThatCancelsGoesNoFurther() {
        let monitor = HotkeyMonitor(hotkey: .rightOption)
        monitor.onEscape = { true }
        #expect(monitor.handle(.keyDown, key(53)))
        monitor.onEscape = { false }   // nothing to cancel: the app in front gets it
        #expect(!monitor.handle(.keyDown, key(53)))
        #expect(!monitor.handle(.keyDown, key(0)))
    }

    @Test func holdingAndReleasingTheHotkey() {
        let monitor = HotkeyMonitor(hotkey: .rightOption)
        var calls: [String] = []
        monitor.onDown = { calls.append("down") }
        monitor.onUp = { calls.append("up") }
        monitor.onChord = { calls.append("chord") }
        let held = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        #expect(!monitor.handle(.flagsChanged, key(61, flags: held)))
        #expect(!monitor.handle(.keyDown, key(0, flags: held)))   // ⌥A: a shortcut, not dictation
        #expect(!monitor.handle(.flagsChanged, key(61)))
        #expect(calls == ["down", "chord", "up"])
    }

    @Test func ourOwnPasteIsIgnored() {
        let monitor = HotkeyMonitor(hotkey: .rightOption)
        var chords = 0
        monitor.onChord = { chords += 1 }
        let held = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        _ = monitor.handle(.flagsChanged, key(61, flags: held))
        let paste = key(9, flags: .maskCommand)
        paste.setIntegerValueField(.eventSourceUserData, value: TextInjector.eventMarker)
        _ = monitor.handle(.keyDown, paste)
        #expect(chords == 0)
    }
}

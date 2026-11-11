import CoreGraphics
import Foundation

/// A modifier key used on its own as the dictation key.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightControl, leftControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "右 Option ⌥"
        case .leftOption: "左 Option ⌥"
        case .rightCommand: "右 Command ⌘"
        case .rightControl: "右 Control ⌃"
        case .leftControl: "左 Control ⌃"
        case .fn: "Fn 🌐"
        }
    }

    var keycap: String {
        switch self {
        case .rightOption: "右⌥"
        case .leftOption: "左⌥"
        case .rightCommand: "右⌘"
        case .rightControl: "右⌃"
        case .leftControl: "左⌃"
        case .fn: "fn"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .leftControl: 59
        case .fn: 63
        }
    }

    init?(keyCode: Int64) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The device-dependent flag bit that is set only while this physical key is down
    /// (so holding the left Option does not count as the right one).
    var heldMask: UInt64 {
        switch self {
        case .rightOption: 0x40
        case .leftOption: 0x20
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .leftControl: 0x01
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// The ordinary modifier flag, for keyboards that don't report which side is down.
    var genericMask: UInt64 {
        switch self {
        case .rightOption, .leftOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl, .leftControl: CGEventFlags.maskControl.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    static let deviceSideMasks: UInt64 = 0x207F

    func isHeld(in flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        if raw & heldMask != 0 { return true }
        return raw & Self.deviceSideMasks == 0 && raw & genericMask != 0
    }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case auto, pushToTalk, toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自适应"
        case .pushToTalk: "按住说话"
        case .toggle: "单击开始 / 结束"
        }
    }

    func detail(_ key: Hotkey) -> String {
        switch self {
        case .auto: "按住 \(key.keycap) 说话、松开结束；或者短按一下开始，说完再按一下结束。"
        case .pushToTalk: "按住 \(key.keycap) 说话，松开就识别并输入。"
        case .toggle: "按一下 \(key.keycap) 开始，再按一下结束。"
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case auto, zh, en, yue, ja, ko

    var id: String { rawValue }

    var short: String {
        switch self {
        case .auto: "自动"
        case .zh: "中文"
        case .en: "英文"
        case .yue: "粤语"
        case .ja: "日语"
        case .ko: "韩语"
        }
    }

    var title: String {
        switch self {
        case .auto: "自动识别（中英混说也行）"
        case .zh: "中文（普通话）"
        case .en: "English"
        case .yue: "粤语"
        case .ja: "日本語"
        case .ko: "한국어"
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var trigger: TriggerMode { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var dropTrailingPeriod: Bool { didSet { defaults.set(dropTrailingPeriod, forKey: "dropTrailingPeriod") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }

    init() {
        hotkey = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        trigger = TriggerMode(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .auto
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        dropTrailingPeriod = defaults.object(forKey: "dropTrailingPeriod") as? Bool ?? false
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        onboarded = defaults.bool(forKey: "onboarded")
    }
}

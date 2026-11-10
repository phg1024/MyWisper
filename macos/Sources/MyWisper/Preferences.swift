import CoreGraphics
import Foundation

/// A modifier key used on its own as the dictation key.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "右 Option ⌥"
        case .rightCommand: "右 Command ⌘"
        case .rightControl: "右 Control ⌃"
        case .fn: "Fn 🌐"
        }
    }

    var keycap: String {
        switch self {
        case .rightOption: "右⌥"
        case .rightCommand: "右⌘"
        case .rightControl: "右⌃"
        case .fn: "fn"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    /// The device-dependent flag bit that is set only while this physical key is down
    /// (so holding the left Option does not count as the right one).
    var heldMask: UInt64 {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
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

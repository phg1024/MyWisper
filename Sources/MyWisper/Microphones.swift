import CoreAudio
import os

private let log = Logger(subsystem: "com.peihongguo.MyWisper", category: "audio")

/// An audio input device.
struct Microphone: Identifiable, Hashable {
    let device: AudioDeviceID
    /// Stable across reboots and reconnects; what the setting stores.
    let uid: String
    let name: String
    let transport: UInt32

    var id: String { uid }
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate }
}

enum Microphones {
    /// The last default input that wasn't a Bluetooth headset: what the user normally records with.
    private static let lastWiredKey = "lastWiredMicrophone"

    static func all() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(microphone)
    }

    static func defaultInput() -> Microphone? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return microphone(id)
    }

    /// The device to record from. `uid` empty means automatic: the system's default input, except that a
    /// Bluetooth headset's microphone is passed over. Opening it switches the headset from music to call
    /// mode, which takes seconds before the first sample arrives and makes everything it plays sound
    /// muffled. Nil: let the system pick.
    static func choose(uid: String) -> Microphone? {
        let pick = pick(uid: uid)
        log.notice("recording from \(pick?.name ?? "the default input", privacy: .public)")
        return pick
    }

    private static func pick(uid: String) -> Microphone? {
        let all = all()
        if !uid.isEmpty, let chosen = all.first(where: { $0.uid == uid }) { return chosen }
        guard let current = defaultInput() else { return nil }
        if !current.isBluetooth {
            UserDefaults.standard.set(current.uid, forKey: lastWiredKey)
            return current
        }
        let others = all.filter { !$0.isBluetooth && !$0.isVirtual }
        let lastWired = UserDefaults.standard.string(forKey: lastWiredKey)
        return others.first { $0.uid == lastWired } ?? others.first(where: \.isBuiltIn) ?? others.first ?? current
    }

    /// Remembers what the user normally records with, while no headset is connected.
    static func noteDefault() {
        if let current = defaultInput(), !current.isBluetooth {
            UserDefaults.standard.set(current.uid, forKey: lastWiredKey)
        }
    }

    private static func microphone(_ id: AudioDeviceID) -> Microphone? {
        // Input channels: a buffer list with at least one channel on the input scope.
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.contains(where: { $0.mNumberChannels > 0 }),
              let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &transportSize, &transport)
        return Microphone(device: id, uid: uid, name: name, transport: transport)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

import AVFoundation

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? { t("没有可用的麦克风", "No microphone available") }
}

/// Captures an input device (the default one unless told otherwise) and converts it to 16 kHz mono float
/// samples for SenseVoice. Talks to the device through its own AUHAL unit rather than AVAudioEngine: the
/// engine's input node first opens the system default input, and when that is a Bluetooth headset it
/// switches the headset to call mode (seconds) even if another device is picked right after.
final class AudioRecorder: @unchecked Sendable {
    /// Called on the main queue every 0.1 s of audio with a 0...1 loudness value (the waveform's pace).
    var onLevel: ((Float) -> Void)?

    private var unit: AudioUnit?
    private var buffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ASREngine.sampleRate),
                                       channels: 1, interleaved: false)!
    /// Converts off the audio thread, in order.
    private let queue = DispatchQueue(label: "com.peihongguo.MyWisper.recorder")
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Loudness over the current 0.1 s, on the queue.
    private var energy: Float = 0
    private var counted = 0

    func start(device: AudioDeviceID? = nil) throws {
        guard let device = device ?? Microphones.defaultInput()?.device else { throw RecorderError.noInput }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &unit) == noErr, let unit else { throw RecorderError.noInput }
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) -> Bool {
            withUnsafePointer(to: value) {
                AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size)) == noErr
            }
        }
        // Input only (element 1), from this device.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)),
              set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)),
              set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device),
              AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
              hardware.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false),
              set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384),
              let converter = AVAudioConverter(from: format, to: target)
        else {
            AudioComponentInstanceDispose(unit)
            throw RecorderError.noInput
        }
        let callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        queue.sync { energy = 0; counted = 0 }
        self.buffer = buffer
        self.converter = converter
        self.unit = unit
        guard set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback),
              AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw RecorderError.noInput
        }
    }

    /// Stops capturing and returns everything recorded since start().
    func stop() -> [Float] {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        queue.sync {}   // what was already captured
        converter = nil
        buffer = nil
        return lock.withLock { samples }
    }

    /// On the audio thread: pulls the new frames and hands a copy to the queue.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * 4
        let status = AudioUnitRender(unit, flags, time, bus, frames, list)
        guard status == noErr, let data = buffer.floatChannelData?[0] else { return status }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(frames)))
        let format = buffer.format
        queue.async { [weak self] in self?.process(chunk, format: format) }
        return noErr
    }

    private func process(_ chunk: [Float], format: AVAudioFormat) {
        guard !chunk.isEmpty else { return }
        // The device hands over ~10 ms at a time; the waveform moves one bar per 0.1 s.
        for x in chunk { energy += x * x }
        counted += chunk.count
        if counted >= Int(format.sampleRate / 10) {
            let rms = sqrt(energy / Float(counted))
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 55) / 45))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
            energy = 0
            counted = 0
        }

        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        input.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        let capacity = AVAudioFrameCount(Double(chunk.count) * target.sampleRate / format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow   // keep the resampler's state for the next buffer
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let converted = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: converted) }
    }
}

enum AudioFile {
    /// Reads any audio file AVFoundation understands as 16 kHz mono floats (for --transcribe).
    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ASREngine.sampleRate),
                                   channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// 16-bit PCM WAV at 16 kHz mono.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(ASREngine.sampleRate)
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
        for sample in samples { put(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}

/// Optional copies of dictations, for comparing recognizers on real speech: each one is a WAV plus a
/// JSON file with what SenseVoice heard, in ~/Library/Application Support/MyWisper/Recordings
/// (owner-only). Off by default; nothing here ever leaves the Mac.
enum RecordingArchive {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyWisper/Recordings")

    static func save(_ samples: [Float], recognized: String, corrected: String?, typed: String,
                     language: Language) {
        DispatchQueue.global(qos: .utility).async {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let base = directory.appendingPathComponent(formatter.string(from: Date()))
            var info: [String: Any] = ["recognized": recognized, "typed": typed,
                                       "language": language.rawValue,
                                       "duration": Double(samples.count) / Double(ASREngine.sampleRate)]
            if let corrected { info["corrected"] = corrected }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try AudioFile.wav(samples).write(to: base.appendingPathExtension("wav"))
                try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                    .write(to: base.appendingPathExtension("json"))
            } catch {
                NSLog("MyWisper: could not save recording: \(error)")
            }
        }
    }
}

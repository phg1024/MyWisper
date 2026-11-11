import AVFoundation

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? { "没有可用的麦克风" }
}

/// Captures the default input device and converts it to 16 kHz mono float samples for SenseVoice.
/// A fresh AVAudioEngine per recording follows device changes (AirPods, USB mics) without extra handling.
final class AudioRecorder: @unchecked Sendable {
    /// Called on the main queue roughly every 20 ms with a 0...1 loudness value.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ASREngine.sampleRate),
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else { throw RecorderError.noInput }
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capturing and returns everything recorded since start().
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 55) / 45))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
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
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
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
}

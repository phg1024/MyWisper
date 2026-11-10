import CSherpaOnnx
import Foundation

struct Transcript {
    let text: String
    let duration: Double   // seconds of audio
    let latency: Double    // seconds spent decoding
}

enum ASRError: LocalizedError {
    case modelMissing(String)
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path): "找不到模型文件：\(path)"
        case .loadFailed: "SenseVoice 模型加载失败"
        }
    }
}

/// SenseVoice-Small through sherpa-onnx's C API. Loading and decoding run on one serial queue,
/// so a transcription requested while the model (re)loads simply waits for it.
final class ASREngine: @unchecked Sendable {
    static let sampleRate = 16000

    private let queue = DispatchQueue(label: "MyWisper.asr", qos: .userInitiated)
    private var recognizer: OpaquePointer?
    private var loadError: Error?

    /// The bundled model, or MYWISPER_MODEL_DIR, or the Python app's model folder (for `swift run`).
    static func defaultModelDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MYWISPER_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("model"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Code/MyWisper/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.int8.onnx").path) }
    }

    func load(modelDirectory: URL?, language: Language, completion: @escaping (Error?) -> Void) {
        queue.async {
            if let old = self.recognizer { SherpaOnnxDestroyOfflineRecognizer(old) }
            self.recognizer = nil
            do {
                self.recognizer = try Self.makeRecognizer(modelDirectory: modelDirectory, language: language)
                self.loadError = nil
            } catch {
                self.loadError = error
            }
            completion(self.loadError)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.decode(samples) })
            }
        }
    }

    private func decode(_ samples: [Float]) throws -> Transcript {
        guard let recognizer else { throw loadError ?? ASRError.loadFailed }
        let start = Date()
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        var text = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            if let raw = result.pointee.text { text = String(cString: raw) }
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        // SenseVoice can leave tags such as <|zh|><|NEUTRAL|><|Speech|> in the text.
        text = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text,
                          duration: Double(samples.count) / Double(Self.sampleRate),
                          latency: Date().timeIntervalSince(start))
    }

    private static func makeRecognizer(modelDirectory: URL?, language: Language) throws -> OpaquePointer {
        guard let dir = modelDirectory else { throw ASRError.modelMissing("model.int8.onnx") }
        let model = dir.appendingPathComponent("model.int8.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        for path in [model, tokens] where !FileManager.default.fileExists(atPath: path) {
            throw ASRError.modelMissing(path)
        }
        // The C structs hold borrowed pointers; keep the copies alive until the recognizer exists.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = c(model)
        config.model_config.sense_voice.language = c(language.rawValue)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = c(tokens)
        config.model_config.num_threads = 4
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else { throw ASRError.loadFailed }
        return recognizer
    }
}

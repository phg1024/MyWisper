import AppKit
import CSherpaOnnx
import CWhisper
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
        case .modelMissing(let path): t("找不到模型文件：\(path)", "Model file not found: \(path)")
        case .loadFailed: t("识别模型加载失败", "Could not load the speech model")
        }
    }
}

/// SenseVoice-Small through sherpa-onnx's C API, or Whisper through whisper.cpp (Metal). Loading and
/// decoding run on one serial queue, so a transcription requested while a model (re)loads waits for it.
final class ASREngine: @unchecked Sendable {
    static let sampleRate = 16000
    static let whisperModelName = "ggml-large-v3-turbo-q8_0.bin"

    private let queue = DispatchQueue(label: "MyWisper.asr", qos: .userInitiated)
    private var recognizer: OpaquePointer?
    private var whisper: OpaquePointer?
    private var language = Language.auto
    private var loadError: Error?

    /// The bundled model, or MYWISPER_MODEL_DIR, or models/ in the current directory (for `swift run`).
    static func defaultModelDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MYWISPER_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("model"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.int8.onnx").path) }
    }

    /// The bundled Whisper model, or MYWISPER_WHISPER_MODEL, or models/whisper/ in the current directory.
    static func whisperModelPath() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["MYWISPER_WHISPER_MODEL"] { candidates.append(env) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("whisper/\(whisperModelName)").path) }
        candidates.append(FileManager.default.currentDirectoryPath + "/models/whisper/\(whisperModelName)")
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func load(_ engine: Recognizer, language: Language, completion: @escaping (Error?) -> Void) {
        queue.async {
            if let old = self.recognizer { SherpaOnnxDestroyOfflineRecognizer(old) }
            if let old = self.whisper { whisper_free(old) }
            self.recognizer = nil
            self.whisper = nil
            self.language = language
            do {
                switch engine {
                case .senseVoice:
                    self.recognizer = try Self.makeRecognizer(modelDirectory: Self.defaultModelDirectory(), language: language)
                case .whisper:
                    self.whisper = try Self.makeWhisper()
                }
                self.loadError = nil
            } catch {
                self.loadError = error
            }
            completion(self.loadError)
        }
    }

    /// Frees the models. Call before the process exits: ggml's Metal device crashes in its exit-time
    /// cleanup if a Whisper context is still alive.
    func unload() {
        queue.sync {
            if let old = self.recognizer { SherpaOnnxDestroyOfflineRecognizer(old) }
            if let old = self.whisper { whisper_free(old) }
            self.recognizer = nil
            self.whisper = nil
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
        if let whisper { return decodeWhisper(whisper, samples) }
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

    private func decodeWhisper(_ context: OpaquePointer, _ samples: [Float]) -> Transcript {
        let start = Date()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = 4
        params.no_context = true
        params.no_timestamps = true
        params.suppress_nst = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // whisper.cpp refuses clips under a second; pad with silence.
        let padded = samples.count >= Self.sampleRate * 11 / 10 ? samples
            : samples + [Float](repeating: 0, count: Self.sampleRate * 11 / 10 - samples.count)
        let code = language == .auto ? "auto" : language.rawValue
        // A punctuated Mandarin prompt nudges Whisper towards simplified characters and punctuation.
        let prompt = ProcessInfo.processInfo.environment["MYWISPER_WHISPER_PROMPT"]
            ?? ([.auto, .zh].contains(language) ? "以下是普通话的句子，有时夹杂英文。" : "")
        var text = ""
        code.withCString { lang in
            prompt.withCString { prompt in
                params.language = lang
                params.initial_prompt = prompt
                padded.withUnsafeBufferPointer { buffer in
                    guard whisper_full(context, params, buffer.baseAddress, Int32(buffer.count)) == 0 else { return }
                    for i in 0..<whisper_full_n_segments(context) {
                        if let segment = whisper_full_get_segment_text(context, i) { text += String(cString: segment) }
                    }
                }
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper often writes Mandarin in traditional characters; this Mac's ICU converts them.
        if language != .yue, let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) {
            text = simplified
        }
        // Whisper puts ASCII punctuation after Chinese characters; use the full-width forms.
        let fullWidth: [Character: String] = [",": "，", "?": "？", "!": "！", ":": "：", ";": "；", ".": "。"]
        text = text.replacing(#/(\p{Han})([,?!:;.])/#) { "\($0.1)\(fullWidth[Character(String($0.2))]!)" }
        return Transcript(text: text,
                          duration: Double(samples.count) / Double(Self.sampleRate),
                          latency: Date().timeIntervalSince(start))
    }

    private static func makeWhisper() throws -> OpaquePointer {
        guard let path = whisperModelPath() else { throw ASRError.modelMissing(whisperModelName) }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(path, params) else { throw ASRError.loadFailed }
        return context
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

/// SenseVoice sometimes emits the end of an English word twice: a whole-word token followed by a
/// piece that repeats its ending ("pending" + "ending", "object" + "ject"). Such a word is removed
/// only when the word as given is misspelled and the word without the repeat is spelled correctly,
/// so real words ("singing", "papa") and names stay as they are. Uses the local spell checker.
enum RepeatedEnding {
    static func fix(_ text: String) -> String {
        var result = text
        let words = text.ranges(of: #/[A-Za-z]{5,}/#).reversed()
        for range in words {
            let word = String(text[range])
            if let fixed = repaired(word) { result.replaceSubrange(range, with: fixed) }
        }
        return result
    }

    private static func repaired(_ word: String) -> String? {
        guard !isWord(word) else { return nil }
        let chars = Array(word)
        // Longest repeat first: "visualualization" drops "ual", not a shorter accident.
        for length in stride(from: chars.count / 2, through: 2, by: -1) {
            for start in 0...(chars.count - 2 * length) {
                guard chars[start..<start + length] == chars[start + length..<start + 2 * length] else { continue }
                var candidate = chars
                candidate.removeSubrange(start + length..<start + 2 * length)
                let fixed = String(candidate)
                if isWord(fixed) { return fixed }
            }
        }
        return nil
    }

    private static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

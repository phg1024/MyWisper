import Foundation
import Testing
@testable import MyWisper

/// Runs the real models; skipped when they aren't on this Mac (./fetch-deps.sh, or the app's Download).
struct SpeechModelTests {
    static let modelDirectory: URL? = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path) ? dir : nil
    }()

    @Test(.enabled(if: modelDirectory != nil), arguments: ["zh", "en", "yue", "ja", "ko"])
    func transcribesTheModelsOwnSamples(_ language: String) async throws {
        let engine = ASREngine()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            engine.load(modelDirectory: Self.modelDirectory, language: .auto) { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
        let samples = try AudioFile.load16kMono(Self.modelDirectory!.appendingPathComponent("test_wavs/\(language).wav"))
        let transcript = try await engine.transcribe(samples)
        #expect(transcript.text == Self.expected[language])
    }

    /// What this model gives (the same as sherpa-onnx's own examples).
    static let expected = [
        "zh": "开饭时间早上9点至下午5点。",
        "en": "The tribal chieftain called for the boy and presented him with 50 pieces of code.",
        "yue": "呢几个字都表达唔到我想讲嘅意思。",
        "ja": "うちの中学は弁当制で持っていきない場合は50円の学校販売のパンを買う。",
        "ko": "조금만 생각을 하면서 살면 훨씬 편할 거야.",
    ]
}

/// The correction model on cases that went wrong before. Loads tens of GB, so only with MYWISPER_LLM_TESTS=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYWISPER_LLM_TESTS"] == "1"))
struct CorrectionModelTests {
    static let corrector: Corrector? = {
        guard let model = CorrectionModel.allCases.first(where: \.isDownloaded),
              (try? Corrector.shared.loadForCommandLine(model)) != nil else { return nil }
        // Freed before llama.cpp's own teardown at exit, which otherwise aborts with Metal still in use.
        atexit { Corrector.shared.shutDown() }
        return Corrector.shared
    }()

    /// Like the app: the learned fixes as hints, their results as vocabulary and as words to keep.
    func correct(_ text: String, fixes: [(String, String)]) async throws -> String {
        let corrector = try #require(Self.corrector, "no correction model downloaded")
        let learned = LearnedFixes(url: nil)
        for (heard, meant) in fixes { learned.learn(typed: "说\(heard)了", edited: "说\(meant)了") }
        return try await corrector.correct(text, vocabulary: learned.terms.joined(separator: ", "),
                                           learned: learned.hints(for: text), keep: learned.keep(vocabulary: ""))
    }

    static let fixes = [("不许", "push"), ("and", "ender"), ("有铺", "有push"), ("肯贝", "commit"), ("对应", "dwin")]

    @Test(arguments: [
        // Heard right; given the other terms the model used to swap it for push.
        ("明天拿ender打一个支架。", "明天拿ender打一个支架。"),
        ("改完记得不许到远端。", "改完记得push到远端。"),
        ("还没有铺到远端的肯贝有几个？", "还没有push到远端的commit有几个？"),
        ("那块对应的屏要用串口来接。", "那块dwin的屏要用串口来接。"),
        // 对应 the ordinary word stays.
        ("这两列数据要一一对应才行。", "这两列数据要一一对应才行。"),
        ("今天天气不错，我们出去走走吧。", "今天天气不错，我们出去走走吧。"),
    ])
    func correctsLikeTheUserWould(_ text: String, _ expected: String) async throws {
        #expect(try await correct(text, fixes: Self.fixes) == expected)
    }

    /// Not solved yet: the model sometimes puts a learned term in place of an ordinary word that sounds
    /// nothing like it, and no check catches that (it doesn't take out one of the user's words).
    @Test func leavesOrdinaryWordsThatSoundNothingLikeATerm() async throws {
        let text = "我买的那块对应的串口屏到了吗？"
        let answer = try await correct(text, fixes: Self.fixes)
        withKnownIssue("对应 → 有push") {
            #expect(answer == text)
        }
    }
}

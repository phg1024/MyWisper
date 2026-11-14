import Foundation
import Testing
@testable import MyWisper

struct LearnedFixesTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID().uuidString).json")

    func fix(_ heard: String, _ meant: String, count: Int = LearnedFixes.confirmAt) -> LearnedFix {
        LearnedFix(heard: heard, meant: meant, count: count, lastSeen: Date())
    }

    @Test func learningTheSameFixAgainConfirmsIt() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧")
        #expect(learned.fixes.map(\.count) == [1])
        #expect(learned.apply("再说一次dation") == "再说一次dation")   // not confirmed yet
        learned.learn(typed: "dation好用", edited: "dictation好用")
        #expect(learned.fixes.map(\.count) == [2])
        #expect(learned.apply("再说一次dation") == "再说一次dictation")
    }

    @Test func aFixMadeInHistoryIsConfirmedAtOnce() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "用不许", edited: "用push", weight: LearnedFixes.confirmAt)
        #expect(learned.fixes.first?.confirmed == true)
    }

    @Test func changingYourMindDropsTheOppositeFix() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "这台ender机器", edited: "这台push机器")
        learned.learn(typed: "这台push机器", edited: "这台ender机器")
        #expect(learned.fixes.map { "\($0.heard) → \($0.meant)" } == ["push → ender"])
    }

    @Test func englishFixesReplaceWholeWordsInAnyCase() {
        let fixes = [fix("deline", "Deline")]
        #expect(LearnedFixes.apply(fixes, to: "DELINE and deline") == "Deline and Deline")
        #expect(LearnedFixes.apply(fixes, to: "delineate") == "delineate")
        #expect(LearnedFixes.apply(fixes, to: "去deline吧") == "去Deline吧")   // Chinese around it is a boundary
    }

    @Test func chineseFixesReplaceEveryOccurrence() {
        #expect(LearnedFixes.apply([fix("和派", "和pi")], to: "键盘和派，鼠标和派") == "键盘和pi，鼠标和pi")
    }

    @Test func longerFixesGoFirst() {
        let fixes = [fix("派", "pi"), fix("树莓派", "Raspberry Pi")]
        #expect(LearnedFixes.apply(fixes, to: "树莓派和派") == "Raspberry Pi和pi")
    }

    @Test func replacementTextIsLiteral() {
        #expect(LearnedFixes.apply([fix("dollar", "$1")], to: "one dollar") == "one $1")
    }

    @Test func hintsPutFixesForThisTextFirst() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧", weight: 5)
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        #expect(learned.hints(for: "可以不许吗") == "不许 → push；dation → dictation")
        #expect(learned.hints(for: "可以不许吗", limit: 1) == "不许 → push")
        #expect(learned.terms == ["dictation", "push"])
    }

    @Test func keepIsVocabularyAndTermsButNotWhatAFixChanges() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        learned.learn(typed: "拿push打支架", edited: "拿ender打支架")
        #expect(learned.keep(vocabulary: "Bambu, OrcaSlicer，Kuma\n Ender ") == ["Bambu", "OrcaSlicer", "Kuma", "Ender"])
        #expect(learned.keep(vocabulary: "") == ["ender"])   // push is what a fix changes
    }

    @Test func containsTerm() {
        #expect(TextDiff.contains("拿Ender打支架", term: "ender"))
        #expect(!TextDiff.contains("rendering", term: "ender"))
        #expect(TextDiff.contains("接上dwin的屏", term: "dwin"))
        #expect(TextDiff.contains("把板清了", term: "板"))
    }

    @Test func termsLeaveOutTheNeighbourKeptForContext() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "昨天没有铺过去", edited: "昨天没有push过去")
        learned.learn(typed: "设计很贵的", edited: "设计很weird的")
        #expect(learned.fixes.map(\.heard) == ["有铺", "很贵"])
        #expect(learned.terms == ["push", "weird"])
        #expect(learned.keep(vocabulary: "") == ["push", "weird"])
        #expect(learned.fixes[0].core == ("铺", "push"))
        #expect(LearnedFix(heard: "dation", meant: "dictation", count: 1, lastSeen: .now).core == ("dation", "dictation"))
        #expect(LearnedFix(heard: "The Luga Halla", meant: "beluga Halluga", count: 1, lastSeen: .now).core == ("The Luga Halla", "beluga Halluga"))
    }

    @Test func fixesSurviveARestart() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let learned = LearnedFixes(url: url)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧")
        let reloaded = LearnedFixes(url: url)
        #expect(reloaded.fixes.map(\.heard) == ["dation"])
        #expect(reloaded.fixes.map(\.meant) == ["dictation"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func deleteAndClear() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧")
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        learned.delete(learned.fixes[0])
        #expect(learned.fixes.map(\.meant) == ["push"])
        learned.clear()
        #expect(learned.fixes.isEmpty)
    }
}

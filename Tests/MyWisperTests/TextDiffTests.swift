import Testing
@testable import MyWisper

struct TextDiffTests {
    func fixes(_ typed: String, _ edited: String) -> [String] {
        TextDiff.fixes(from: typed, to: edited).map { "\($0.heard) → \($0.meant)" }
    }

    @Test func tokensSplitEnglishWordsFromEveryOtherCharacter() {
        #expect(TextDiff.tokens("用pi打3D件") == ["用", "pi", "打", "3D", "件"])
        #expect(TextDiff.tokens("don't stop.") == ["don't", " ", "stop", "."])
        #expect(TextDiff.tokens("") == [])
    }

    @Test func diffFindsSubstitutionsInsertionsAndDeletions() {
        let hunks = TextDiff.diff(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(hunks.map(\.start) == [1, 3])
        #expect(hunks.map(\.removed) == [["b"], []])
        #expect(hunks.map(\.added) == [["x"], ["d"]])
    }

    @Test func englishWordMisheard() {
        #expect(fixes("我想试试用dation写邮件", "我想试试用dictation写邮件") == ["dation → dictation"])
    }

    @Test func chineseHeardAsEnglishTerm() {
        #expect(fixes("改完记得不许到远端。", "改完记得push到远端。") == ["不许 → push"])
    }

    @Test func singleChineseCharacterKeepsANeighbour() {
        // 道 → 岛 alone would rewrite every 道; with its neighbour it is specific.
        #expect(fixes("我们去大道上看看", "我们去大岛上看看") == ["大道 → 大岛"])
    }

    @Test func twoChangesInOneSentence() {
        #expect(fixes("还没有铺到远端的肯贝有几个", "还没有push到远端的commit有几个") == ["有铺 → 有push", "肯贝 → commit"])
    }

    @Test func wordsSeparatedOnlyBySpaceAreOneChange() {
        #expect(fixes("The Luga Halla.", "beluga Halluga.") == ["The Luga Halla → beluga Halluga"])
    }

    @Test func addingOrDeletingWordsIsNotAFix() {
        #expect(fixes("我去吃饭", "我马上去吃饭") == [])
        #expect(fixes("我马上去吃饭", "我去吃饭") == [])
    }

    @Test func aRewriteIsNotAFix() {
        #expect(fixes("今天天气很好我们出去走走吧", "明天要下雨所以留在家里看书") == [])
    }

    @Test func nothingChanged() {
        #expect(fixes("一样的话", "一样的话") == [])
        #expect(fixes("", "加了一句") == [])
    }

    @Test func shortCaseChangesAreIgnoredButLongOnesKept() {
        #expect(fixes("把pi接上网", "把Pi接上网") == [])
        #expect(fixes("放到github上", "放到GitHub上") == ["github → GitHub"])
    }

    @Test func punctuationOnlyIsNotAFix() {
        #expect(fixes("好吧。", "好吧！") == [])
        #expect(fixes("你好，我是谁", "你好。我是谁") == [])
    }

    @Test func mergeAsksVetAboutEveryChange() {
        var seen: [String] = []
        let merged = TextDiff.merge("我用派打印", "我用pi打印了") { original, edited in
            seen.append("\(original)|\(edited)")
            return edited
        }
        #expect(merged == "我用pi打印了")
        #expect(seen == ["派|pi", "|了"])
    }

    @Test func mergeCanUndoAChange() {
        #expect(TextDiff.merge("Eruption来了", "喷发来了") { original, _ in original } == "Eruption来了")
    }
}

import Testing
@testable import MyWisper

/// The checks around the language model's answer; the model itself is in ModelTests.
struct CorrectorTests {
    @Test func vetUndoesTranslatingEnglish() {
        #expect(Corrector.vet("Eruption", "喷发") == "Eruption")
        #expect(Corrector.vet("派", "pi") == "pi")
        #expect(Corrector.vet("dation", "dictation") == "dictation")
    }

    @Test func vetUndoesSpacingChanges() {
        #expect(Corrector.vet(" ", "  ") == " ")
        #expect(Corrector.vet("", " ") == "")
        #expect(Corrector.vet("派", " pi ") == "pi")
        #expect(Corrector.vet(" 派", " pi") == " pi")
    }

    @Test func respaceDropsSpacesBetweenChineseAndEnglish() {
        #expect(Corrector.respace("用 pi 打印", like: "用派打印") == "用pi打印")
        #expect(Corrector.respace("用 3D 打印", like: "用3D打印") == "用3D打印")
    }

    @Test func respaceKeepsSpacesTheRecognizerHad() {
        #expect(Corrector.respace("用 pi 打印", like: "用 pi 打印") == "用 pi 打印")
        #expect(Corrector.respace("hello world", like: "hello word") == "hello world")
    }

    @Test func answerStripsThinkingAndTags() {
        #expect(Corrector.answer("<think>\n\n</think>\n\n<text>我的pi要接显示屏</text>", for: "我的派要接显示屏") == "我的pi要接显示屏")
    }

    @Test func answerKeepsEnglishTheModelTranslated() {
        #expect(Corrector.answer("<text>火山喷发了吗</text>", for: "火山Eruption了吗") == "火山Eruption了吗")
    }

    @Test func answerRejectsReplies() {
        #expect(Corrector.answer("好的，以下是修改后的文字：改完记得push到远端。如果还有其他需要请告诉我。",
                                 for: "改完记得不许到远端。") == nil)
        #expect(Corrector.answer("", for: "改完记得不许到远端。") == nil)
    }

    @Test func answerKeepsTheUsersTermsWhereTheyWere() {
        let keep = ["ender", "push", "commit"]
        #expect(Corrector.answer("<text>拿push打支架</text>", for: "拿ender打支架", keep: keep) == "拿ender打支架")
        #expect(Corrector.answer("<text>拿Ender打支架</text>", for: "拿ender打支架", keep: keep) == "拿Ender打支架")
        #expect(Corrector.answer("<text>改完记得push到远端</text>", for: "改完记得不许到远端", keep: keep) == "改完记得push到远端")
        #expect(Corrector.answer("<text>用dwin的屏</text>", for: "用对应的屏", keep: ["dwin"]) == "用dwin的屏")
    }

    @Test func answerCountsEnglishWordsAsWordsNotLetters() {
        #expect(Corrector.answer("还没有 push 到远端的 commit 有几个？", for: "还没有铺到远端的肯贝有几个？") == "还没有push到远端的commit有几个？")
    }

    @Test func answerAllowsShortPhrasesSomeSlack() {
        #expect(Corrector.answer("Aloha!", for: "啊lo下。") == "Aloha!")
    }
}

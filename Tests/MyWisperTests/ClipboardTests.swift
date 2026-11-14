import AppKit
import Testing
@testable import MyWisper

@MainActor
struct ClipboardTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyWisperTests-\(UUID().uuidString)"))

    init() {
        pasteboard.clearContents()
        pasteboard.setString("the user's own", forType: .string)
    }

    func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func putsTheUsersClipboardBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("dictated", restoreAfter: 0.05)
        #expect(pasteboard.string(forType: .string) == "dictated")
        await wait(0.2)
        #expect(pasteboard.string(forType: .string) == "the user's own")
    }

    @Test func twoPastesInARowStillPutTheUsersClipboardBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.1)
        swap.put("second", restoreAfter: 0.1)
        #expect(pasteboard.string(forType: .string) == "second")
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "the user's own")
    }

    @Test func somethingTheUserCopiedMeanwhileStays() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("dictated", restoreAfter: 0.1)
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func somethingCopiedBetweenTwoPastesIsWhatComesBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.1)
        pasteboard.clearContents()
        pasteboard.setString("copied in between", forType: .string)
        swap.put("second", restoreAfter: 0.1)
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "copied in between")
    }

    @Test func withoutRestoringTheTextStays() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.05)
        swap.put("kept", restoreAfter: nil)
        await wait(0.2)
        #expect(pasteboard.string(forType: .string) == "kept")
    }

    @Test func pastedTextIsTransient() {
        ClipboardSwap(pasteboard).put("dictated", restoreAfter: 1)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
    }
}

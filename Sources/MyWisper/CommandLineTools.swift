import AppKit
import SwiftUI

/// Headless modes, used by build.sh and for testing without the menu bar:
///   MyWisper --transcribe a.wav [b.wav ...] [--language zh]
///   MyWisper --snapshot <dir> [en|zh]  renders the main views to PNG
///   MyWisper --make-icon <dir.iconset>
///   MyWisper --microphones             lists the inputs and the one a recording would use
///   MyWisper --record <seconds> <out.wav> [microphone UID]   records like the hotkey does
enum CommandLineTools {
    static func run(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        switch args[1] {
        case "--transcribe":
            transcribe(Array(args.dropFirst(2)))
        case "--snapshot" where args.count > 2:
            if args.count > 3 { Preferences.languageOverride = UILanguage(rawValue: args[3]) }
            MainActor.assumeIsolated { snapshot(into: URL(fileURLWithPath: args[2])) }
        case "--make-icon" where args.count > 2:
            MainActor.assumeIsolated { makeIcon(URL(fileURLWithPath: args[2])) }
        case "--microphones":
            let chosen = Microphones.choose(uid: Preferences.shared.microphone)
            for mic in Microphones.all() {
                print("\(mic.uid == chosen?.uid ? "*" : " ") \(mic.name)\(mic.isBluetooth ? " (Bluetooth)" : "")\(mic.isVirtual ? " (virtual)" : "")")
            }
        case "--record" where args.count > 3:
            record(seconds: Double(args[2]) ?? 3, to: URL(fileURLWithPath: args[3]), uid: args.count > 4 ? args[4] : Preferences.shared.microphone)
        default:
            return false   // e.g. -NSDocumentRevisionsDebugMode from Xcode
        }
        return true
    }

    private static func record(seconds: Double, to url: URL, uid: String) {
        let recorder = AudioRecorder()
        let started = Date()
        var first: TimeInterval?
        recorder.onLevel = { _ in if first == nil { first = Date().timeIntervalSince(started) } }
        do {
            try recorder.start(device: Microphones.choose(uid: uid)?.device)
        } catch {
            print("error: \(error.localizedDescription)")
            return
        }
        let opened = Date().timeIntervalSince(started)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let samples = recorder.stop()
        try? AudioFile.wav(samples).write(to: url)
        print(String(format: "opened in %.2f s, first sound after %.2f s, %.2f s recorded", opened, first ?? -1,
                     Double(samples.count) / Double(ASREngine.sampleRate)))
    }

    private static func transcribe(_ args: [String]) {
        var files = args
        var language = Language.auto
        let correct = files.contains("--correct")
        files.removeAll { $0 == "--correct" }
        let vocabulary = ProcessInfo.processInfo.environment["MYWISPER_VOCABULARY"] ?? ""
        if correct {
            // MYWISPER_LLM_MODEL=/path/to/model.gguf, or the downloaded recommended model.
            do { try Corrector.shared.loadForCommandLine(.recommended) } catch { print("correction model: \(error.localizedDescription)"); exit(1) }
        }
        if let i = files.firstIndex(of: "--language"), i + 1 < files.count {
            language = Language(rawValue: files[i + 1]) ?? .auto
            files.removeSubrange(i...(i + 1))
        }
        let engine = ASREngine()
        let loaded = DispatchSemaphore(value: 0)
        var failure: Error?
        let start = Date()
        engine.load(modelDirectory: ASREngine.defaultModelDirectory(), language: language) { failure = $0; loaded.signal() }
        loaded.wait()
        if let failure { print("load failed: \(failure.localizedDescription)"); exit(1) }
        print(String(format: "model loaded in %.2f s (language %@)", Date().timeIntervalSince(start), language.rawValue))
        for file in files {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let samples = try AudioFile.load16kMono(URL(fileURLWithPath: file))
                    let t = try await engine.transcribe(samples)
                    let text = LearnedFixes.shared.apply(RepeatedEnding.fix(t.text))
                    print(String(format: "%.1fs audio, %.0f ms | %@", t.duration, t.latency * 1000, text))
                    if correct {
                        let start = Date()
                        let fixed = try await Corrector.shared.correct(text, vocabulary: vocabulary,
                                                                       learned: LearnedFixes.shared.hints(for: text),
                                                                       keep: LearnedFixes.shared.keep(vocabulary: vocabulary))
                        print(String(format: "  corrected in %.0f ms | %@", Date().timeIntervalSince(start) * 1000, fixed))
                    }
                } catch {
                    print("\(file): \(error.localizedDescription)")
                }
                done.signal()
            }
            done.wait()
        }
        Corrector.shared.shutDown()
    }

    // MARK: Snapshots

    @MainActor
    private static func snapshot(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()
        let samples = [
            ("帮我把明天下午三点的会改到四点，顺便提醒一下 Peter 带上投影仪。", 120.0, 4.1),
            ("Let's ship the beta on Friday and collect feedback over the weekend.", 900.0, 3.2),
            ("晚饭吃什么？", 4000.0, 1.1),
        ]
        let entries = samples.map { HistoryEntry(date: now.addingTimeInterval(-$0.1), text: $0.0, duration: $0.2, latency: 0.05) }
        let history = HistoryStore(url: nil, entries: entries)
        let empty = HistoryStore(url: nil, entries: [])

        func menu(_ model: AppModel, _ store: HistoryStore) -> some View {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.prefs)
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(menu(.preview(history: history), history).environment(\.colorScheme, scheme), to: dir.appendingPathComponent("menu-\(suffix).png"), scheme: scheme)
            render(menu(.preview(recording: true, latched: true, history: history), history).environment(\.colorScheme, scheme),
                   to: dir.appendingPathComponent("menu-recording-\(suffix).png"), scheme: scheme)
        }
        render(menu(.preview(permissions: false, history: empty), empty), to: dir.appendingPathComponent("menu-setup.png"), scheme: .light)

        let model = AppModel.preview(recording: true, history: history)
        let hudKinds: [(String, HUDState.Kind)] = [
            ("recording", .recording),
            ("transcribing", .transcribing),
            ("done", .done("帮我把明天下午三点的会改到四点，顺便提醒一下 Peter 带上投影仪。", pasted: true)),
            ("copied", .done("晚饭吃什么？", pasted: false)),
            ("message", .message("没有听到声音", symbol: "waveform.slash")),
        ]
        for (name, kind) in hudKinds {
            let state = HUDState()
            state.kind = kind
            let view = HUDView().environmentObject(state).environmentObject(model).environmentObject(model.prefs)
                .background(Color(white: 0.55))
            render(view, to: dir.appendingPathComponent("hud-\(name).png"), scheme: .dark)
        }

        let settingsModel = AppModel.preview(history: history)
        render(SettingsView().environmentObject(settingsModel).environmentObject(settingsModel.prefs).environmentObject(history)
               .background(Color(nsColor: .windowBackgroundColor)),
               to: dir.appendingPathComponent("settings.png"), scheme: .light)
        render(AboutSettings().environmentObject(settingsModel).environmentObject(history).frame(width: 520)
               .background(Color(nsColor: .windowBackgroundColor)),
               to: dir.appendingPathComponent("about.png"), scheme: .light)
        render(WelcomeView().environmentObject(AppModel.preview(permissions: false, history: empty)).environmentObject(Preferences())
               .background(Color(nsColor: .windowBackgroundColor)),
               to: dir.appendingPathComponent("welcome.png"), scheme: .light)
        print("snapshots in \(dir.path)")
    }

    /// Draws through a real (offscreen) window, so AppKit-backed controls such as pickers render too.
    @MainActor
    private static func render<V: View>(_ view: V, to url: URL, scheme: ColorScheme) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    // MARK: Icon

    @MainActor
    private static func makeIcon(_ iconset: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconArt())
        renderer.scale = 1
        guard let full = renderer.cgImage else { print("icon render failed"); exit(1) }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: full, size: NSSize(width: 1024, height: 1024))
                    .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
            }
        }
    }
}

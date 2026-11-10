import AppKit
import AVFoundation
import Combine
import ServiceManagement

/// The one place that knows whether we are recording. The hotkey, the menu button and the HUD
/// all go through it, so they can never disagree about the state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(prefs: .shared, history: .shared)

    enum ModelState: Equatable {
        case loading, ready, failed(String)
    }

    let prefs: Preferences
    let history: HistoryStore
    let hud: HUDController

    @Published private(set) var modelState: ModelState = .loading
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart = Date()
    /// Recording keeps going after the key is released; the next press ends it.
    @Published private(set) var latched = false
    @Published private(set) var pending = 0
    @Published private(set) var levels = [Float](repeating: 0, count: AppModel.levelCount)
    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var hotkeyActive = false

    static let levelCount = 28
    static let maxRecording: TimeInterval = 300
    static let holdThreshold: TimeInterval = 0.35

    private let engine = ASREngine()
    private let recorder = AudioRecorder()
    private let hotkeys: HotkeyMonitor
    private var subscriptions = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var feedback: DispatchWorkItem?
    private var pressTime = Date()
    private var pressStartedRecording = false

    init(prefs: Preferences, history: HistoryStore) {
        self.prefs = prefs
        self.history = history
        self.hotkeys = HotkeyMonitor(hotkey: prefs.hotkey)
        self.hud = HUDController()
        hud.model = self
    }

    // MARK: Launch

    func launch() {
        history.persist = prefs.saveHistory
        loadModel()
        recorder.onLevel = { [weak self] level in self?.push(level: level) }

        hotkeys.onDown = { [weak self] in MainActor.assumeIsolated { self?.hotkeyDown() } }
        hotkeys.onUp = { [weak self] in MainActor.assumeIsolated { self?.hotkeyUp() } }
        hotkeys.onChord = { [weak self] in MainActor.assumeIsolated { self?.hotkeyChord() } }
        hotkeys.onEscape = { [weak self] in MainActor.assumeIsolated { self?.cancel() } }
        hotkeyActive = hotkeys.start()

        prefs.$hotkey.dropFirst().sink { [weak self] key in self?.hotkeys.hotkey = key }.store(in: &subscriptions)
        prefs.$language.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.loadModel() }   // after the new value is stored
        }.store(in: &subscriptions)
        prefs.$saveHistory.sink { [weak self] on in self?.history.persist = on }.store(in: &subscriptions)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func loadModel() {
        modelState = .loading
        engine.load(modelDirectory: ASREngine.defaultModelDirectory(), language: prefs.language) { [weak self] error in
            DispatchQueue.main.async {
                self?.modelState = error.map { .failed($0.localizedDescription) } ?? .ready
            }
        }
    }

    // MARK: Permissions

    var needsPermissions: Bool { micStatus != .authorized || !accessibilityGranted }

    func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted && !hotkeys.isRunning { hotkeyActive = hotkeys.start() }
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        default:
            openSettings("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings("Privacy_Accessibility") }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Hotkey

    private func hotkeyDown() {
        pressTime = Date()
        switch prefs.trigger {
        case .pushToTalk:
            if isRecording { stop() } else { pressStartedRecording = start(latched: false) }
        case .toggle:
            if isRecording { stop() } else { pressStartedRecording = start(latched: true) }
        case .auto:
            if isRecording {
                if latched { stop() }
            } else {
                pressStartedRecording = start(latched: false)
            }
        }
    }

    private func hotkeyUp() {
        defer { pressStartedRecording = false }
        guard isRecording, pressStartedRecording else { return }
        switch prefs.trigger {
        case .pushToTalk:
            stop()
        case .toggle:
            break
        case .auto:
            if Date().timeIntervalSince(pressTime) >= Self.holdThreshold {
                stop()
            } else {
                latched = true   // a tap: keep listening until the next press
            }
        }
    }

    /// ⌥E, ⌘C, ⌥-click...: the key was a modifier for something else, not a dictation.
    private func hotkeyChord() {
        if isRecording && pressStartedRecording { cancel(silently: true) }
        pressStartedRecording = false
    }

    // MARK: Recording

    /// From the menu or HUD: start (ends with the next hotkey press) or finish.
    func toggleFromUI() {
        if isRecording {
            stop()
        } else {
            NSApp.hide(nil)   // give focus back to the app the text should go into
            start(latched: true)
        }
    }

    @discardableResult
    private func start(latched: Bool) -> Bool {
        guard !isRecording else { return false }
        guard micStatus == .authorized else {
            requestMicrophone()
            hud.flash(.message("需要麦克风权限", symbol: "mic.slash"))
            return false
        }
        do {
            try recorder.start()
        } catch {
            hud.flash(.message(error.localizedDescription, symbol: "mic.slash"))
            return false
        }
        self.latched = latched
        isRecording = true
        recordingStart = Date()
        levels = Array(repeating: 0, count: Self.levelCount)
        // Sound and HUD wait a moment, so a ⌥E typed with the dictation key shows nothing at all.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            if self.prefs.sounds { Sounds.start() }
            self.hud.show(.recording)
        }
        feedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        return true
    }

    func stop() {
        guard isRecording else { return }
        let samples = finishRecording()
        let duration = Double(samples.count) / Double(ASREngine.sampleRate)
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard duration >= 0.3, rms >= 0.001 else {
            if prefs.sounds { Sounds.error() }
            hud.flash(.message(duration < 0.3 ? "录音太短" : "没有听到声音", symbol: "waveform.slash"))
            return
        }
        if prefs.sounds { Sounds.stop() }
        pending += 1
        hud.show(.transcribing)
        Task {
            defer { pending -= 1 }
            do {
                deliver(try await engine.transcribe(samples))
            } catch {
                if !isRecording { hud.flash(.message(error.localizedDescription, symbol: "exclamationmark.triangle")) }
            }
        }
    }

    func cancel(silently: Bool = false) {
        guard isRecording else { return }
        _ = finishRecording()
        if silently { hud.hide() } else { hud.flash(.message("已取消", symbol: "xmark.circle")) }
    }

    private func finishRecording() -> [Float] {
        feedback?.cancel()
        feedback = nil
        let samples = recorder.stop()
        isRecording = false
        latched = false
        pressStartedRecording = false
        return samples
    }

    private func push(level: Float) {
        guard isRecording else { return }
        levels.removeFirst()
        levels.append(level)
        if Date().timeIntervalSince(recordingStart) > Self.maxRecording { stop() }
    }

    private func deliver(_ transcript: Transcript) {
        var text = transcript.text
        if prefs.dropTrailingPeriod, let last = text.last, "。.".contains(last) { text.removeLast() }
        guard !text.isEmpty else {
            if !isRecording { hud.flash(.message("没有识别出文字", symbol: "questionmark.circle")) }
            return
        }
        history.add(transcript, text: text)
        let pasted = prefs.autoPaste && TextInjector.paste(text, restoreClipboard: prefs.restoreClipboard)
        if !pasted { TextInjector.copy(text) }
        if !isRecording { hud.flash(.done(text, pasted: pasted)) }
    }

    // MARK: Menu text

    var statusLine: String {
        if isRecording { return latched ? "正在听… 再按 \(prefs.hotkey.keycap) 结束" : "正在听…" }
        if pending > 0 { return "识别中…" }
        switch modelState {
        case .loading: return "正在加载模型…"
        case .failed(let message): return message
        case .ready:
            if !hotkeyActive { return "快捷键还不能用：需要辅助功能权限" }
            return prefs.trigger == .toggle ? "按 \(prefs.hotkey.keycap) 开始说话" : "按住 \(prefs.hotkey.keycap) 说话"
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MyWisper login item: \(error)")
            }
        }
    }

    // MARK: Previews

    /// A model in a fixed state, for --snapshot.
    static func preview(recording: Bool = false, latched: Bool = false, permissions: Bool = true,
                        history: HistoryStore) -> AppModel {
        let model = AppModel(prefs: Preferences(), history: history)
        model.modelState = .ready
        model.isRecording = recording
        model.latched = latched
        model.recordingStart = Date().addingTimeInterval(-4.2)
        model.levels = (0..<levelCount).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
        model.micStatus = permissions ? .authorized : .notDetermined
        model.accessibilityGranted = permissions
        model.hotkeyActive = permissions
        return model
    }
}

enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Funk") }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }
}

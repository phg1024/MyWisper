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
    /// Settings is waiting for the user to press the key they want.
    @Published private(set) var capturingHotkey = false
    @Published private(set) var captureNote: String?

    static let levelCount = 28
    static let maxRecording: TimeInterval = 300
    static let holdThreshold: TimeInterval = 0.35
    /// The microphone opens this long after the key goes down, so ⌃C or ⌥E never touches it.
    static let armDelay: TimeInterval = 0.12

    private let engine = ASREngine()
    private let recorder = AudioRecorder()
    private let hotkeys: HotkeyMonitor
    private var subscriptions = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var feedback: DispatchWorkItem?
    private var pressTime = Date()
    private var pressStartedRecording = false
    private var pendingStart: DispatchWorkItem?
    private var captureTimeout: DispatchWorkItem?

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
        if accessibilityGranted { hotkeyActive = hotkeys.start() }

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
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityGranted || trusted != hotkeys.isRunning else { return }
        accessibilityGranted = trusted
        // A tap made without Accessibility only ever sees our own app's keys, so build a fresh one
        // whenever the grant changes rather than keeping the old one.
        hotkeys.stop()
        hotkeyActive = trusted && hotkeys.start()
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
        if isRecording {
            if prefs.trigger != .auto || latched { stop() }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStart = nil
            self.pressStartedRecording = self.start(latched: self.prefs.trigger == .toggle)
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay, execute: work)
    }

    private func hotkeyUp() {
        if let work = pendingStart {
            // Released before the microphone opened: a quick tap, which starts a hands-free recording.
            work.cancel()
            pendingStart = nil
            if prefs.trigger != .pushToTalk { start(latched: true) }
            return
        }
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
        pendingStart?.cancel()
        pendingStart = nil
        if isRecording && pressStartedRecording { cancel(silently: true) }
        pressStartedRecording = false
    }

    // MARK: Choosing the key

    /// Settings' "press the key" button. Goes through the same event tap, so it also proves the tap works.
    func beginHotkeyCapture() {
        captureNote = nil
        guard hotkeys.isRunning else {
            captureNote = t("快捷键监听还没启动：先在「权限」里授权辅助功能", "The shortcut listener isn’t running yet: grant Accessibility under Permissions first")
            return
        }
        cancel(silently: true)
        capturingHotkey = true
        hotkeys.onCapture = { [weak self] type, code, flags in
            MainActor.assumeIsolated { self?.captured(type, code, flags) ?? false }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.endHotkeyCapture(note: t("没等到按键，再试一次", "No key pressed. Try again")) }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func endHotkeyCapture(note: String? = nil) {
        captureTimeout?.cancel()
        hotkeys.onCapture = nil
        capturingHotkey = false
        captureNote = note
    }

    private func captured(_ type: CGEventType, _ code: Int64, _ flags: CGEventFlags) -> Bool {
        if type == .keyDown {
            if code == 53 { endHotkeyCapture() } else { captureNote = t("要用单独的修饰键：Option、Control、右 Command 或 Fn", "Use a modifier key on its own: Option, Control, right Command or Fn") }
            return true
        }
        guard let key = Hotkey(keyCode: code) else {
            if flags.rawValue & Hotkey.deviceSideMasks != 0 || flags.contains(.maskShift) || flags.contains(.maskCommand) {
                captureNote = t("这个键不行：Shift 和左 Command 太常用，请换一个", "Not that one: Shift and left Command are used too often. Pick another key")
            }
            return true
        }
        guard key.isHeld(in: flags) else { return true }   // the release
        prefs.hotkey = key
        endHotkeyCapture(note: t("已设为 \(key.title)", "Set to \(key.title)"))
        return true
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
            hud.flash(.message(t("需要麦克风权限", "Microphone access needed"), symbol: "mic.slash"))
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
        if prefs.correction { Corrector.warmUp(endpoint: prefs.correctionEndpoint, model: prefs.correctionModel) }
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
            hud.flash(.message(duration < 0.3 ? t("录音太短", "Too short") : t("没有听到声音", "Didn’t hear anything"), symbol: "waveform.slash"))
            return
        }
        if prefs.sounds { Sounds.stop() }
        pending += 1
        hud.show(.transcribing)
        Task {
            defer { pending -= 1 }
            do {
                let transcript = try await engine.transcribe(samples)
                let recognized = RepeatedEnding.fix(transcript.text)
                var corrected: String?
                if prefs.correction, !recognized.isEmpty {
                    corrected = try? await Corrector.correct(recognized, vocabulary: prefs.vocabulary,
                                                             endpoint: prefs.correctionEndpoint, model: prefs.correctionModel)
                }
                let text = deliver(transcript, text: corrected ?? recognized)
                if prefs.saveRecordings {
                    RecordingArchive.save(samples, recognized: transcript.text, corrected: corrected, typed: text,
                                          language: prefs.language)
                }
            } catch {
                if !isRecording { hud.flash(.message(error.localizedDescription, symbol: "exclamationmark.triangle")) }
            }
        }
    }

    func cancel(silently: Bool = false) {
        pendingStart?.cancel()
        pendingStart = nil
        guard isRecording else { return }
        _ = finishRecording()
        if silently { hud.hide() } else { hud.flash(.message(t("已取消", "Cancelled"), symbol: "xmark.circle")) }
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

    /// Types or copies the text and returns it.
    @discardableResult
    private func deliver(_ transcript: Transcript, text recognized: String) -> String {
        var text = recognized
        if prefs.dropTrailingPeriod, let last = text.last, "。.".contains(last) { text.removeLast() }
        guard !text.isEmpty else {
            if !isRecording { hud.flash(.message(t("没有识别出文字", "No speech recognized"), symbol: "questionmark.circle")) }
            return text
        }
        history.add(transcript, text: text)
        let pasted = prefs.autoPaste && TextInjector.paste(text, restoreClipboard: prefs.restoreClipboard)
        if !pasted { TextInjector.copy(text) }
        if !isRecording { hud.flash(.done(text, pasted: pasted)) }
        return text
    }

    // MARK: Menu text

    var statusLine: String {
        if isRecording { return latched ? t("正在听… 再按 \(prefs.hotkey.keycap) 结束", "Listening… press \(prefs.hotkey.keycap) again to finish") : t("正在听…", "Listening…") }
        if pending > 0 { return t("识别中…", "Transcribing…") }
        switch modelState {
        case .loading: return t("正在加载模型…", "Loading model…")
        case .failed(let message): return message
        case .ready:
            if !hotkeyActive { return t("快捷键还不能用：需要辅助功能权限", "Shortcut not working yet: needs Accessibility access") }
            return prefs.trigger == .toggle ? t("按 \(prefs.hotkey.keycap) 开始说话", "Press \(prefs.hotkey.keycap) to start talking") : t("按住 \(prefs.hotkey.keycap) 说话", "Hold \(prefs.hotkey.keycap) and talk")
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

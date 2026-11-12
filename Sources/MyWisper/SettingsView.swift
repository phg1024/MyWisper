import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(t("通用", "General"), systemImage: "gearshape") }
            PermissionSettings().tabItem { Label(t("权限", "Permissions"), systemImage: "lock.shield") }
            AboutSettings().tabItem { Label(t("关于", "About"), systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("界面语言 / Language", selection: $prefs.uiLanguage) {
                    ForEach(UILanguage.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker(t("快捷键", "Shortcut"), selection: $prefs.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent {
                    if model.capturingHotkey {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(t("请按一下要用的键…", "Press the key you want…")).foregroundStyle(.secondary)
                            Button(t("取消", "Cancel")) { model.endHotkeyCapture() }.controlSize(.small)
                        }
                    } else {
                        Button(t("按键设置…", "Record Key…")) { model.beginHotkeyCapture() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("直接按要用的键", "Set by pressing the key"))
                        if let note = model.captureNote {
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(t("用法", "Mode"), selection: $prefs.trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(t("快捷键", "Shortcut"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prefs.trigger.detail(prefs.hotkey))
                    Text(t("按着快捷键时又按了别的键（比如 ⌃C、⌥E），这次录音会自动作废；录音时按 esc 取消。", "If you press another key while holding the shortcut (like ⌃C or ⌥E), that recording is discarded. Press esc to cancel a recording."))
                    if prefs.hotkey == .fn {
                        Text(t("Fn 键默认会弹出表情或切换输入法：请在 系统设置 › 键盘 里把「按下 🌐 键时」改成「无操作」。", "By default Fn opens the emoji picker or switches input sources: set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”."))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(t("语言提示", "Language hint"), selection: $prefs.language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                TextField(t("常用词", "Vocabulary"), text: $prefs.vocabulary,
                          prompt: Text(t("比如 GitHub, Expedia, 万豪 Bonvoy", "e.g. GitHub, Expedia, Marriott Bonvoy")))
                Toggle(t("去掉句末的句号", "Drop the final period"), isOn: $prefs.dropTrailingPeriod)
            } header: {
                Text(t("识别", "Recognition"))
            } footer: {
                Text(t("SenseVoice 会自己判断说的是哪种语言，语言提示多数时候选「自动」就好。常用词填你常说的名字和术语，用逗号隔开，下面的纠错会参考它。", "SenseVoice detects the language by itself; Auto is right most of the time. Vocabulary: names and terms you often say, separated by commas, used by the correction below."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(t("用本机大模型纠正听错的词", "Fix misheard words with a local language model"), isOn: $prefs.correction)
                if prefs.correction {
                    TextField(t("地址", "Endpoint"), text: $prefs.correctionEndpoint)
                    if !Corrector.isLoopback(prefs.correctionEndpoint) {
                        Text(t("只能用本机地址（127.0.0.1 或 localhost）。", "Only addresses on this Mac (127.0.0.1 or localhost) are allowed."))
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(t("纠错（实验）", "Correction (experimental)"))
            } footer: {
                Text(t("识别完把文字交给这台 Mac 上运行的模型（OpenAI 兼容接口，比如 llama.cpp、LM Studio），按上下文改正同音字和专有名词。每句多花大约半秒；模型没开或超过 \(Int(Corrector.timeout)) 秒就直接用原来的结果。只连本机，文字不会离开这台 Mac。", "Sends the text to a model running on this Mac (an OpenAI-compatible server such as llama.cpp or LM Studio) to fix sound-alike words and names from context. Adds about half a second; if the server is off or takes more than \(Int(Corrector.timeout)) s, the text is used as recognized. Loopback only: the text never leaves this Mac."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(t("输入", "Input")) {
                Toggle(t("识别完自动粘贴到光标处", "Paste at the cursor when done"), isOn: $prefs.autoPaste)
                Toggle(t("粘贴后恢复原来的剪贴板", "Restore the clipboard after pasting"), isOn: $prefs.restoreClipboard)
                    .disabled(!prefs.autoPaste)
            }

            Section(t("其他", "Other")) {
                Toggle(t("提示音", "Sounds"), isOn: $prefs.sounds)
                Toggle(t("登录时自动启动", "Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle(t("保存历史记录", "Keep history"), isOn: $prefs.saveHistory)
                Toggle(isOn: $prefs.saveRecordings) {
                    Text(t("保存录音", "Save recordings"))
                    Text(t("用来排查识别问题。只存在本机，不会上传。", "For tracking down recognition problems. Kept on this Mac only."))
                }
                if prefs.saveRecordings {
                    HStack {
                        Text(t("录音", "Recordings")).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("在访达中显示", "Show in Finder")) {
                            try? FileManager.default.createDirectory(at: RecordingArchive.directory, withIntermediateDirectories: true,
                                                                     attributes: [.posixPermissions: 0o700])
                            NSWorkspace.shared.activateFileViewerSelecting([RecordingArchive.directory])
                        }
                    }
                }
                HStack {
                    Text(t("历史记录", "History")).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("清空…", "Clear…")) { confirmClear = true }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .confirmationDialog(t("清空全部 \(history.entries.count) 条历史记录？", "Clear all \(history.entries.count) history entries?"), isPresented: $confirmClear) {
            Button(t("清空", "Clear"), role: .destructive) { history.clear() }
        } message: {
            Text(t("这一步不能撤销。", "This can’t be undone."))
        }
    }
}

private struct PermissionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: t("麦克风", "Microphone"), detail: t("录下你说的话。音频只在本机识别，不会上传。", "Records what you say. Audio is recognized on this Mac and never uploaded."),
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: t("辅助功能", "Accessibility"), detail: t("监听快捷键（全局），并模拟 ⌘V 把文字粘贴到光标处。", "Listens for the shortcut in every app and sends ⌘V to paste text at the cursor."),
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
            } footer: {
                Text(t("重新编译过 MyWisper 后，系统会把它当成新程序：到 系统设置 › 隐私与安全性 › 辅助功能 里用「−」删掉旧的 MyWisper，再点这里的「授权」重新添加。", "If the shortcut stops working after an update, remove MyWisper with “−” in System Settings › Privacy & Security › Accessibility, then click Grant here to add it again."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

/// Opened in the browser only when clicked; the app itself never connects anywhere.
enum Links {
    static let repository = URL(string: "https://github.com/phg1024/MyWisper")!
    static let sponsors = URL(string: "https://github.com/sponsors/phg1024")!
    static let coffee = URL(string: "https://buymeacoffee.com/phg1024")!
}

struct AboutSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 72)
            VStack(spacing: 4) {
                Text("MyWisper").font(.system(size: 20, weight: .semibold))
                Text(t("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")", "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(t("本地语音输入。识别模型是 SenseVoice-Small（int8，sherpa-onnx），音频和文字都不离开这台 Mac。", "On-device dictation with SenseVoice-Small (int8, sherpa-onnx). Audio and text never leave this Mac."))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(t("模型", "Model")).foregroundStyle(.secondary)
                    Text(modelText).textSelection(.enabled)
                }
                GridRow {
                    Text(t("平均识别耗时", "Average recognition time")).foregroundStyle(.secondary)
                    Text(history.recentLatency.map { String(format: t("%.0f 毫秒（最近 %d 次）", "%.0f ms (last %d)"), $0 * 1000, min(20, history.entries.count)) } ?? t("还没有数据", "No data yet"))
                }
            }
            .font(.system(size: 12))
            HStack(spacing: 10) {
                Link(destination: Links.repository) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Links.sponsors) {
                    Label { Text("Sponsor") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                Link(destination: Links.coffee) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(t("MyWisper 免费开源。觉得好用的话，欢迎请我喝杯咖啡。", "MyWisper is free and open source. If it helps you, a coffee is always appreciated."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(t("SenseVoice-Small 模型来自 FunAudioLLM（阿里巴巴通义实验室），遵循 FunASR 模型开源协议；sherpa-onnx（Apache-2.0）、ONNX Runtime（MIT）。详见 App 包内的 THIRD_PARTY_NOTICES.md。", "SenseVoice-Small by FunAudioLLM (Tongyi Lab, Alibaba Group), under the FunASR Model Open Source License; sherpa-onnx (Apache-2.0), ONNX Runtime (MIT). See THIRD_PARTY_NOTICES.md inside the app."))
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 400)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .frame(height: 440)
    }

    private var modelText: String {
        switch model.modelState {
        case .loading: t("加载中…", "Loading…")
        case .failed(let message): message
        case .ready: ASREngine.defaultModelDirectory()?.lastPathComponent == "model" ? t("随 App 打包", "Bundled with the app") : (ASREngine.defaultModelDirectory()?.path ?? "")
        }
    }
}

struct HistoryWindow: View {
    @EnvironmentObject var history: HistoryStore
    @State private var query = ""

    var body: some View {
        let shown = query.isEmpty ? history.entries : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        Group {
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? t("还没有记录", "No history yet") : t("没有找到", "No matches"),
                                       systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { entry in
                            HistoryRow(entry: entry, compact: false) { history.delete(entry) }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: t("搜索", "Search"))
        .frame(minWidth: 420, minHeight: 360)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                AppGlyph(size: 64)
                Text(t("欢迎使用 MyWisper", "Welcome to MyWisper")).font(.system(size: 22, weight: .semibold))
                Text(t("说话，文字就出现在光标处。全部在本机完成。", "Talk, and the text appears at your cursor. Everything stays on this Mac."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(title: t("1. 允许使用麦克风", "1. Allow the microphone"), detail: t("点「授权」，在弹窗里选「允许」。", "Click Grant, then Allow in the dialog."),
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: t("2. 允许辅助功能", "2. Allow Accessibility"),
                              detail: t("点「授权」后会打开系统设置，在列表里打开 MyWisper 的开关。用来监听快捷键和粘贴文字。", "Click Grant to open System Settings, then turn on MyWisper in the list. It’s used for the shortcut and for pasting."),
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("3. 试一下", "3. Try it")).font(.system(size: 13, weight: .medium))
                        (Text(prefs.trigger.detail(prefs.hotkey) + t(" 菜单栏的 ", " The ")) + Text(Image(systemName: "waveform"))
                            + Text(t(" 里可以看历史、改设置。", " menu bar icon has history and settings.")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

            Button {
                prefs.onboarded = true
                dismissWindow(id: "welcome")
            } label: {
                Text(model.needsPermissions ? t("稍后再说", "Later") : t("开始使用", "Get Started")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 460)
    }
}

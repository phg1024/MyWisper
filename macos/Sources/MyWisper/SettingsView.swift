import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            PermissionSettings().tabItem { Label("权限", systemImage: "lock.shield") }
            AboutSettings().tabItem { Label("关于", systemImage: "info.circle") }
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
                Picker("快捷键", selection: $prefs.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Picker("用法", selection: $prefs.trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("快捷键")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prefs.trigger.detail(prefs.hotkey))
                    Text("按着快捷键时又按了别的键（比如 ⌘C、⌥E），这次录音会自动作废；录音时按 esc 取消。")
                    if prefs.hotkey == .fn {
                        Text("Fn 键默认会弹出表情或切换输入法：请在 系统设置 › 键盘 里把「按下 🌐 键时」改成「无操作」。")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("语言提示", selection: $prefs.language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                Toggle("去掉句末的句号", isOn: $prefs.dropTrailingPeriod)
            } header: {
                Text("识别")
            } footer: {
                Text("SenseVoice 会自己判断说的是哪种语言，这里只是提示，多数时候选「自动」就好；粤语和普通话分不清时可以指定。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("输入") {
                Toggle("识别完自动粘贴到光标处", isOn: $prefs.autoPaste)
                Toggle("粘贴后恢复原来的剪贴板", isOn: $prefs.restoreClipboard)
                    .disabled(!prefs.autoPaste)
            }

            Section("其他") {
                Toggle("提示音", isOn: $prefs.sounds)
                Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("保存历史记录", isOn: $prefs.saveHistory)
                HStack {
                    Text("历史记录").foregroundStyle(.secondary)
                    Spacer()
                    Button("清空…") { confirmClear = true }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .confirmationDialog("清空全部 \(history.entries.count) 条历史记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { history.clear() }
        } message: {
            Text("这一步不能撤销。")
        }
    }
}

private struct PermissionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "麦克风", detail: "录下你说的话。音频只在本机识别，不会上传。",
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: "辅助功能", detail: "监听快捷键（全局），并模拟 ⌘V 把文字粘贴到光标处。",
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
            } footer: {
                Text("重新编译过 MyWisper 后，系统会把它当成新程序：到 系统设置 › 隐私与安全性 › 辅助功能 里用「−」删掉旧的 MyWisper，再点这里的「授权」重新添加。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

private struct AboutSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 72)
            VStack(spacing: 4) {
                Text("MyWisper").font(.system(size: 20, weight: .semibold))
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("本地语音输入。识别模型是 SenseVoice-Small（int8，sherpa-onnx），音频和文字都不离开这台 Mac。")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("模型").foregroundStyle(.secondary)
                    Text(modelText).textSelection(.enabled)
                }
                GridRow {
                    Text("平均识别耗时").foregroundStyle(.secondary)
                    Text(history.recentLatency.map { String(format: "%.0f 毫秒（最近 %d 次）", $0 * 1000, min(20, history.entries.count)) } ?? "还没有数据")
                }
            }
            .font(.system(size: 12))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }

    private var modelText: String {
        switch model.modelState {
        case .loading: "加载中…"
        case .failed(let message): message
        case .ready: ASREngine.defaultModelDirectory()?.lastPathComponent == "model" ? "随 App 打包" : (ASREngine.defaultModelDirectory()?.path ?? "")
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
                ContentUnavailableView(query.isEmpty ? "还没有记录" : "没有找到",
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
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
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
                Text("欢迎使用 MyWisper").font(.system(size: 22, weight: .semibold))
                Text("说话，文字就出现在光标处。全部在本机完成。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(title: "1. 允许使用麦克风", detail: "点「授权」，在弹窗里选「允许」。",
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: "2. 允许辅助功能",
                              detail: "点「授权」后会打开系统设置，在列表里打开 MyWisper 的开关。用来监听快捷键和粘贴文字。",
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("3. 试一下").font(.system(size: 13, weight: .medium))
                        (Text(prefs.trigger.detail(prefs.hotkey) + " 菜单栏的 ") + Text(Image(systemName: "waveform"))
                            + Text(" 里可以看历史、改设置。"))
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
                Text(model.needsPermissions ? "稍后再说" : "开始使用").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 460)
    }
}

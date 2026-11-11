import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var history: HistoryStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            RecordButton()
            if model.needsPermissions { permissionBanner }
            recent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("MyWisper").font(.system(size: 14, weight: .semibold))
                Text(model.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(statusIsWarning ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(model.statusLine)
        }
    }

    private var statusIsWarning: Bool {
        if case .failed = model.modelState { return true }
        return model.modelState == .ready && !model.hotkeyActive && !model.isRecording
    }

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.pending > 0 || model.modelState == .loading { return .yellow }
        return statusIsWarning ? .orange : .green
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("还差一步：授权后才能用", "One more step: grant access to start"), systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            if model.micStatus != .authorized {
                PermissionRow(title: t("麦克风", "Microphone"), detail: t("录下你说的话，只在本机识别", "Records what you say; recognized on this Mac only"), granted: false) {
                    model.requestMicrophone()
                }
            }
            if !model.accessibilityGranted {
                PermissionRow(title: t("辅助功能", "Accessibility"), detail: t("监听快捷键，把文字粘贴到光标处", "Listens for the shortcut and pastes text at the cursor"), granted: false) {
                    model.requestAccessibility()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(t("最近", "Recent"))
                Spacer()
                if !history.entries.isEmpty {
                    Button(t("全部记录", "All history")) { show(window: "history") }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            if history.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text(t("还没有记录。在任意输入框里\(prefs.trigger == .toggle ? "按" : "按住") \(prefs.hotkey.keycap) 说话试试。", "Nothing yet. In any text field, \(prefs.trigger == .toggle ? "press" : "hold") \(prefs.hotkey.keycap) and say something."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.entries.prefix(5)) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Label(t("设置", "Settings"), systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Spacer()
            Button(t("退出", "Quit")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func show(window id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false

    var body: some View {
        Button { model.toggleFromUI() } label: {
            HStack(spacing: 10) {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                Text(model.isRecording ? t("结束并输入", "Finish and insert") : t("开始听写", "Start dictation"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isRecording {
                    Waveform(levels: Array(model.levels.suffix(14)), color: .white)
                        .frame(width: 54, height: 18)
                    ElapsedText(start: model.recordingStart)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                } else if model.modelState == .loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Keycap(text: prefs.hotkey.keycap, onColor: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.isRecording ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(Brand.gradient)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(model.modelState != .ready && !model.isRecording)
        .animation(.easeOut(duration: 0.15), value: model.isRecording)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.isRecording ? "mic.fill" : (model.pending > 0 ? "ellipsis.circle" : "waveform"))
            .onAppear {
                // First launch, or permissions lost (e.g. after a rebuild): show the setup window.
                if !model.prefs.onboarded || model.needsPermissions {
                    openWindow(id: "welcome")
                    NSApp.activate()
                }
            }
    }
}

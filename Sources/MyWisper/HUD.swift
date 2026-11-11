import AppKit
import SwiftUI

final class HUDState: ObservableObject {
    enum Kind: Equatable {
        case hidden
        case recording
        case transcribing
        case done(String, pasted: Bool)
        case message(String, symbol: String)
    }

    @Published var kind: Kind = .hidden
}

/// A click-through capsule near the bottom of the screen the mouse is on. It never takes focus,
/// so the app being typed into stays frontmost.
@MainActor
final class HUDController {
    let state = HUDState()
    weak var model: AppModel?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    static let size = NSSize(width: 620, height: 96)

    func show(_ kind: HUDState.Kind) {
        hideWork?.cancel()
        generation += 1
        state.kind = kind
        guard let panel = panel ?? makePanel() else { return }
        place(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Shows a result or message, then fades out.
    func flash(_ kind: HUDState.Kind, for seconds: TimeInterval = 1.8) {
        show(kind)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { state.kind = .hidden; return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }   // shown again meanwhile
                panel.orderOut(nil)
                self.state.kind = .hidden
            }
        })
    }

    private func makePanel() -> NSPanel? {
        guard let model else { return nil }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView()
            .environmentObject(state)
            .environmentObject(model)
            .environmentObject(model.prefs))
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 36))
    }
}

struct HUDView: View {
    @EnvironmentObject var hud: HUDState
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if hud.kind != .hidden {
                content
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .background(Capsule().fill(Color.black.opacity(0.84)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .padding(.bottom, 14)
        .frame(width: HUDController.size.width, height: HUDController.size.height)
        .animation(.spring(duration: 0.28, bounce: 0.2), value: hud.kind)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch hud.kind {
        case .hidden:
            EmptyView()
        case .recording:
            HStack(spacing: 12) {
                PulsingDot()
                Waveform(levels: model.levels, color: .white)
                    .frame(width: 120, height: 24)
                ElapsedText(start: model.recordingStart)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 34, alignment: .leading)
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(t("识别中…", "Transcribing…")).font(.system(size: 13, weight: .medium))
            }
        case .done(let text, let pasted):
            HStack(spacing: 10) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .foregroundStyle(pasted ? .green : .yellow)
                    .font(.system(size: 16))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if !pasted {
                    Text(t("已复制，⌘V 粘贴", "Copied. Press ⌘V to paste")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize()
                }
            }
        case .message(let text, let symbol):
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.orange)
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
        }
    }

    private var hint: String {
        if model.latched || prefs.trigger == .toggle { return t("再按 \(prefs.hotkey.keycap) 结束 · esc 取消", "Press \(prefs.hotkey.keycap) again to finish · esc to cancel") }
        if prefs.trigger == .pushToTalk { return t("松开结束 · esc 取消", "Release to finish · esc to cancel") }
        return t("松开结束 · esc 取消", "Release to finish · esc to cancel")
    }
}

struct PulsingDot: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .phaseAnimator([1.0, 0.35]) { dot, phase in
                dot.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

struct Waveform: View {
    var levels: [Float]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color.opacity(0.35 + 0.65 * Double(level)))
                        .frame(height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

struct ElapsedText: View {
    var start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

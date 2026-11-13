import SwiftUI

enum Brand {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.33, green: 0.42, blue: 0.98), Color(red: 0.62, green: 0.32, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Brand.gradient)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// The macOS app icon: a squircle on the standard 1024 grid with a little room for the shadow.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Brand.gradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            Image(systemName: "waveform")
                .font(.system(size: 430, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Keycap: View {
    var text: String
    var onColor = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onColor ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(onColor ? Color.white.opacity(0.35) : Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}

struct SectionLabel: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var compact = true
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .opacity(hovering || copied ? 1 : 0)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .help(t("点击复制", "Click to copy"))
        .contextMenu {
            Button(t("复制", "Copy")) { copy() }
            if let onEdit { Button(t("改正…", "Correct…"), action: onEdit) }
            if let onDelete { Button(t("删除", "Delete"), role: .destructive, action: onDelete) }
        }
    }

    private var caption: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Preferences.shared.locale
        let when = Date().timeIntervalSince(entry.date) < 60 ? t("刚才", "just now") : formatter.localizedString(for: entry.date, relativeTo: Date())
        return t("\(when) · \(String(format: "%.1f", entry.duration)) 秒", "\(when) · \(String(format: "%.1f", entry.duration)) s")
    }

    private func copy() {
        TextInjector.copy(entry.text)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(t("授权", "Grant"), action: action).controlSize(.small)
            }
        }
    }
}

import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var text: String
    var duration: Double
    var latency: Double
}

/// Dictation history in ~/Library/Application Support/MyWisper/history.json (owner-only).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 500

    @Published private(set) var entries: [HistoryEntry] = []
    /// Off: this session's dictations stay in memory only and nothing is written to disk.
    var persist = true
    private let url: URL?

    init(url: URL? = HistoryStore.defaultURL(), entries: [HistoryEntry]? = nil) {
        self.url = url
        if let entries {
            self.entries = entries
        } else if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MyWisper/history.json")
    }

    func add(_ transcript: Transcript, text: String) {
        entries.insert(HistoryEntry(date: Date(), text: text, duration: transcript.duration, latency: transcript.latency), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Empties the list and the file, even when saving is off.
    func clear() {
        entries.removeAll()
        let keep = persist
        persist = true
        save()
        persist = keep
    }

    /// Mean decoding time of recent dictations, for the About page.
    var recentLatency: Double? {
        let recent = entries.prefix(20)
        return recent.isEmpty ? nil : recent.map(\.latency).reduce(0, +) / Double(recent.count)
    }

    private func save() {
        guard persist, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

import Foundation
import Combine

/// One correction the user made: what was typed, and what they changed it to.
struct LearnedFix: Codable, Identifiable, Hashable {
    var id = UUID()
    var heard: String
    var meant: String
    /// Times the user made this fix. A fix made in History counts as two.
    var count: Int
    var lastSeen: Date

    /// Applied to new dictations without asking the language model.
    var confirmed: Bool { count >= LearnedFixes.confirmAt }
}

/// Fixes learned from the user's own corrections, in ~/Library/Application Support/MyWisper/learned.json
/// (owner-only). Only the changed words are kept, never the text around them.
final class LearnedFixes: ObservableObject {
    static let shared = LearnedFixes()
    static let confirmAt = 2
    static let limit = 1000

    @Published private(set) var fixes: [LearnedFix] = []
    private let url: URL?

    init(url: URL? = LearnedFixes.defaultURL()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            fixes = (try? decoder.decode([LearnedFix].self, from: data)) ?? []
        }
    }

    /// MYWISPER_LEARNED: another file, for trying things out from the command line.
    static func defaultURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["MYWISPER_LEARNED"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MyWisper/learned.json")
    }

    /// Learns from the user turning `typed` into `edited`. Returns the fixes it recorded.
    @discardableResult
    func learn(typed: String, edited: String, weight: Int = 1) -> [(heard: String, meant: String)] {
        let pairs = TextDiff.fixes(from: typed, to: edited)
        for (heard, meant) in pairs {
            if let i = fixes.firstIndex(where: { $0.heard == heard && $0.meant == meant }) {
                fixes[i].count += weight
                fixes[i].lastSeen = Date()
            } else {
                fixes.append(LearnedFix(heard: heard, meant: meant, count: weight, lastSeen: Date()))
            }
            // The user changed their mind: an older fix of the same words the other way round goes.
            fixes.removeAll { $0.heard == meant && $0.meant == heard }
        }
        if fixes.count > Self.limit {
            fixes.sort { $0.lastSeen > $1.lastSeen }
            fixes.removeLast(fixes.count - Self.limit)
        }
        if !pairs.isEmpty { save() }
        return pairs
    }

    /// Applies the confirmed fixes, longest first.
    func apply(_ text: String) -> String {
        Self.apply(fixes.filter(\.confirmed), to: text)
    }

    static func apply(_ fixes: [LearnedFix], to text: String) -> String {
        var text = text
        for fix in fixes.sorted(by: { $0.heard.count > $1.heard.count }) {
            if fix.heard.allSatisfy({ $0.isASCII }) {
                // English: whole words only, any case ("Deline" as well as "deline").
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: fix.heard) + "(?![A-Za-z0-9])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                      withTemplate: NSRegularExpression.escapedTemplate(for: fix.meant))
            } else {
                text = text.replacingOccurrences(of: fix.heard, with: fix.meant)
            }
        }
        return text
    }

    /// For the corrector's prompt: fixes that may matter for this text, most relevant first.
    func hints(for text: String, limit: Int = 20) -> String {
        let relevant = fixes.sorted { a, b in
            let (ina, inb) = (text.localizedCaseInsensitiveContains(a.heard), text.localizedCaseInsensitiveContains(b.heard))
            return ina != inb ? ina : (a.count, a.lastSeen) > (b.count, b.lastSeen)
        }
        return relevant.prefix(limit).map { "\($0.heard) → \($0.meant)" }.joined(separator: "；")
    }

    /// Words the user has corrected to, for the corrector's vocabulary.
    var terms: [String] {
        var seen = Set<String>()
        return fixes.sorted { $0.count > $1.count }.map(\.meant).filter { seen.insert($0).inserted }
    }

    func delete(_ fix: LearnedFix) {
        fixes.removeAll { $0.id == fix.id }
        save()
    }

    func clear() {
        fixes.removeAll()
        save()
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(fixes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Finds the word substitutions between what was typed and what the user turned it into.
enum TextDiff {
    /// Substitutions only: added or deleted words are the user writing more, not fixing a mishearing.
    /// Nothing at all when the edit looks like a rewrite rather than a fix.
    static func fixes(from typed: String, to edited: String) -> [(heard: String, meant: String)] {
        let a = tokens(typed), b = tokens(edited)
        guard typed != edited, !a.isEmpty, a.count * b.count <= 400_000 else { return [] }
        let hunks = diff(a, b)
        let changed = hunks.reduce(0) { $0 + max($1.removed.count, $1.added.count) }
        guard changed * 2 <= a.count, hunks.count <= 6 else { return [] }

        var result: [(String, String)] = []
        for hunk in hunks where !hunk.removed.isEmpty && !hunk.added.isEmpty {
            var removed = hunk.removed, added = hunk.added
            var start = hunk.start, end = hunk.start + removed.count
            // A single Chinese character means little on its own (道 → 岛); keep a neighbour for context (大道 → 大岛).
            while removed.joined().count < 2 && !isWord(removed.joined()) {
                if start > 0, !isSpace(a[start - 1]) {
                    start -= 1
                    removed.insert(a[start], at: 0)
                    added.insert(a[start], at: 0)
                } else if end < a.count, !isSpace(a[end]) {
                    removed.append(a[end])
                    added.append(a[end])
                    end += 1
                } else {
                    break
                }
            }
            let heard = removed.joined().trimmingCharacters(in: .whitespaces)
            let meant = added.joined().trimmingCharacters(in: .whitespaces)
            guard heard != meant, heard.count >= 2, heard.count <= 24, meant.count <= 40,
                  heard.contains(where: { $0.isLetter }) || meant.contains(where: { $0.isLetter }),
                  heard.lowercased() != meant.lowercased() || heard.count > 3 else { continue }
            result.append((heard, meant))
        }
        return result
    }

    /// English words and numbers as one token each; every other character on its own.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "'" || ch == "’") {
                word.append(ch)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(ch))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    struct Hunk { var start: Int; var removed: [String]; var added: [String] }

    /// Longest-common-subsequence diff of two token lists.
    static func diff(_ a: [String], _ b: [String]) -> [Hunk] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var current: Hunk?
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                if let h = current { hunks.append(h); current = nil }
                i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                if current == nil { current = Hunk(start: i, removed: [], added: []) }
                current!.added.append(b[j]); j += 1
            } else {
                if current == nil { current = Hunk(start: i, removed: [], added: []) }
                current!.removed.append(a[i]); i += 1
            }
        }
        if let h = current { hunks.append(h) }
        return hunks
    }

    private static func isWord(_ s: String) -> Bool { s.count >= 2 && s.allSatisfy { $0.isASCII } }
    private static func isSpace(_ s: String) -> Bool { s.allSatisfy { $0.isWhitespace || $0.isPunctuation } }
}

import Foundation
import Testing
@testable import MyWisper

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MyWisperTests-\(UUID().uuidString)")
}

@MainActor
struct TrainingDataTests {
    let directory = temporaryDirectory()
    let second = [Float](repeating: 0.1, count: 16000)

    func permissions(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    @Test func savesAudioAndIndexForTheOwnerOnly() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = TrainingData(directory: directory)
        let id = UUID()
        data.add(id: id, audio: second, recognized: "用派打", text: "用派打", label: .unchanged)
        let wav = directory.appendingPathComponent("\(id.uuidString).wav")
        #expect(FileManager.default.fileExists(atPath: wav.path))
        #expect(permissions(directory) == 0o700)
        #expect(permissions(wav) == 0o600)
        #expect(permissions(directory.appendingPathComponent("samples.json")) == 0o600)
        #expect(data.totalDuration == 1)

        let reloaded = TrainingData(directory: directory)
        #expect(reloaded.samples.map(\.id) == [id])
        #expect(reloaded.samples.first?.label == .unchanged)
    }

    @Test func anEditRelabelsTheSample() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = TrainingData(directory: directory)
        let id = UUID()
        data.add(id: id, audio: second, recognized: "用派打", text: "用派打", label: .unchanged)
        data.update(id, text: "用pi打")
        #expect(data.samples.first?.text == "用pi打")
        #expect(data.samples.first?.recognized == "用派打")
        #expect(data.samples.first?.label == .edited)
    }

    @Test func overTheLimitUnconfirmedSamplesGoFirst() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = TrainingData(directory: directory, limit: 2)
        let ids = (0..<3).map { _ in UUID() }
        data.add(id: ids[0], audio: second, recognized: "a", text: "a", label: .unchanged)
        data.update(ids[0], text: "b")   // the oldest, but the user confirmed it
        data.add(id: ids[1], audio: second, recognized: "c", text: "c", label: .modelChanged)
        data.add(id: ids[2], audio: second, recognized: "d", text: "d", label: .unchanged)
        #expect(data.samples.map(\.id) == [ids[0], ids[2]])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(ids[1].uuidString).wav").path))
    }

    @Test func removeAndClearDeleteTheAudio() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = TrainingData(directory: directory)
        let ids = [UUID(), UUID()]
        for id in ids { data.add(id: id, audio: second, recognized: "a", text: "a", label: .unchanged) }
        data.remove(ids[0])
        #expect(data.samples.map(\.id) == [ids[1]])
        data.clear()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(left == ["samples.json"])
    }
}

struct HistoryStoreTests {
    let url = temporaryDirectory().appendingPathComponent("history.json")
    let transcript = Transcript(text: "", duration: 2, latency: 0.1)

    @Test func newestFirstAndCapped() {
        let history = HistoryStore(url: nil)
        for i in 0..<(HistoryStore.limit + 5) { history.add(transcript, text: "\(i)") }
        #expect(history.entries.count == HistoryStore.limit)
        #expect(history.entries.first?.text == "\(HistoryStore.limit + 4)")
    }

    @Test func persistsUnlessTurnedOff() {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = HistoryStore(url: url)
        let id = history.add(transcript, text: "一")
        history.update(id, text: "二")
        #expect(HistoryStore(url: url).entries.map(\.text) == ["二"])
        history.persist = false
        history.add(transcript, text: "三")
        #expect(HistoryStore(url: url).entries.map(\.text) == ["二"])
        history.clear()   // empties the file even with saving off
        #expect(HistoryStore(url: url).entries.isEmpty)
    }

    @Test func recentLatency() {
        let history = HistoryStore(url: nil)
        #expect(history.recentLatency == nil)
        history.add(Transcript(text: "", duration: 1, latency: 0.2), text: "a")
        history.add(Transcript(text: "", duration: 1, latency: 0.4), text: "b")
        #expect(abs(history.recentLatency! - 0.3) < 1e-9)
    }
}

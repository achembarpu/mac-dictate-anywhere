import Foundation

/// Enqueued synchronously by Settings so snapshots cannot overtake a deletion.
/// Only the serial queue encodes and writes; flush joins everything already queued.
nonisolated final class TranscriptHistoryPersistence: Sendable {
    private let queue = DispatchQueue(label: "com.dictate-anywhere.history", qos: .utility)
    private let suiteName: String?
    private let key: String

    init(suiteName: String? = nil, key: String = "transcriptHistory") {
        self.suiteName = suiteName
        self.key = key
    }

    func save(_ entries: [TranscriptHistoryEntry]) {
        let suiteName = suiteName, key = key
        queue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            // Create Foundation's non-Sendable store on its writing queue.
            let defaults: UserDefaults
            if let suiteName {
                guard let scoped = UserDefaults(suiteName: suiteName) else { return }
                defaults = scoped
            } else {
                defaults = .standard
            }
            defaults.set(data, forKey: key)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

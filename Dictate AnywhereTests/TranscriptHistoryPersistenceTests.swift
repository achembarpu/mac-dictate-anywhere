import XCTest
@testable import Dictate_Anywhere

@MainActor
final class TranscriptHistoryPersistenceTests: XCTestCase {
    func testQueuedSnapshotsCannotRestoreDeletedHistory() async throws {
        let suite = "history-persistence-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = TranscriptHistoryPersistence(suiteName: suite)
        let entry = TranscriptHistoryEntry(id: UUID(), text: String(repeating: "A long transcript. ", count: 5_000),
                                           createdAt: Date(), rawText: "Unedited words.")
        persistence.save([entry])
        persistence.save([])
        await persistence.flush()
        let data = try XCTUnwrap(defaults.data(forKey: "transcriptHistory"))
        XCTAssertEqual(try JSONDecoder().decode([TranscriptHistoryEntry].self, from: data), [])
    }

    func testFlushPreservesFinalAndRawTextInTheExistingFormat() async throws {
        let suite = "history-persistence-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = TranscriptHistoryPersistence(suiteName: suite)
        let entry = TranscriptHistoryEntry(id: UUID(), text: "Meet at five.", createdAt: Date(),
                                           rawText: "Um meet at five.")
        persistence.save([entry])
        await persistence.flush()
        let data = try XCTUnwrap(defaults.data(forKey: "transcriptHistory"))
        XCTAssertEqual(try JSONDecoder().decode([TranscriptHistoryEntry].self, from: data), [entry])
    }
}

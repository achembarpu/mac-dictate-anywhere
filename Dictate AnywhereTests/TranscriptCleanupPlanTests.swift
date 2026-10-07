import XCTest
@testable import Dictate_Anywhere

final class TranscriptCleanupPlanTests: XCTestCase {
    func testShortInputUsesOneFitCheckAndKeepsSeparators() async throws {
        var calls = 0
        let input = "  Keep 43.\n"
        let chunks = try await TranscriptCleanupPlan.chunks(input) { _ in calls += 1; return true }
        XCTAssertEqual(chunks.map(\.original).joined(), input)
        XCTAssertEqual(calls, 1)
    }

    func testSourceParagraphsKeepEverySeparatorAndRepeatedRecord() {
        for text in ["", "  ", "\n\nFirst.\n\n\n\nFirst.\n\n", "甲。\n\n乙。  "] {
            let paragraphs = TranscriptCleanupPlan.paragraphs(text)
            XCTAssertEqual(paragraphs.map(\.original).joined(), text)
            XCTAssertEqual(paragraphs.map { $0.replacingText(with: $0.text) }.joined(), text)
        }
        XCTAssertEqual(TranscriptCleanupPlan.paragraphs("First.\n\nFirst.").map(\.text), ["First.", "First."])
    }
    func testPartitionsPreserveEveryCharacterAndPreferSentenceBoundaries() async throws {
        let text = "  First sentence.\n\nSecond sentence with 42 euros.\nLast words.  "
        let chunks = try await TranscriptCleanupPlan.chunks(text) { $0.utf8.count <= 35 }
        XCTAssertEqual(chunks.map(\.original).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.original.utf8.count <= 35 })
        XCTAssertEqual(chunks.first?.text, "First sentence.")
        XCTAssertEqual(chunks.map { $0.replacingText(with: $0.text) }.joined(), text)
    }

    func testChineseWithoutSpacesSplitsAtPunctuationWithoutInsertingSpaces() async throws {
        let text = "请发送报告。明天上午开会！最后保留名字。"
        let chunks = try await TranscriptCleanupPlan.chunks(text) { $0.count <= 10 }
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.original).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.original.count <= 10 })
    }

    func testUnbrokenIdentifierFailsInsteadOfSplittingOrDroppingIt() async {
        do {
            _ = try await TranscriptCleanupPlan.chunks("long_identifier_without_spaces") { $0.count <= 8 }
            XCTFail("An identifier must stay intact")
        } catch { XCTAssertTrue(error is CleanupResponseError) }
    }

    func testWhitespaceAndEmptyInputAreLossless() async throws {
        let empty = try await TranscriptCleanupPlan.chunks("") { _ in true }
        XCTAssertTrue(empty.isEmpty)
        let spaces = try await TranscriptCleanupPlan.chunks(" \n\t") { _ in true }
        XCTAssertEqual(spaces.map(\.original).joined(), " \n\t")
        XCTAssertEqual(spaces.first?.text, "")
    }

    func testCancellationStopsPlanning() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranscriptCleanupPlan.chunks("some words") { _ in true }
        }
        do { _ = try await task.value; XCTFail("Cancelled work must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testChatCompletionRejectsTruncationFilteringAndRefusal() throws {
        for reason in ["length", "content_filter", "tool_calls", "error"] {
            let json = "{\"choices\":[{\"finish_reason\":\"\(reason)\",\"message\":{\"content\":\"partial\"}}]}"
            let response = try JSONDecoder().decode(CleanupChatCompletion.self, from: Data(json.utf8))
            XCTAssertThrowsError(try response.completeText(), reason)
        }
        let refused = try JSONDecoder().decode(CleanupChatCompletion.self, from: Data(
            #"{"choices":[{"finish_reason":"stop","message":{"content":null,"refusal":"Refused"}}]}"#.utf8))
        XCTAssertThrowsError(try refused.completeText())
    }

    func testChatCompletionAcceptsTextPartsAndAbsentOptionalFinishMetadata() throws {
        for json in [
            #"{"choices":[{"finish_reason":"stop","message":{"content":" Complete. "}}]}"#,
            #"{"choices":[{"message":{"content":[{"text":"Complete."}]}}]}"#
        ] {
            let response = try JSONDecoder().decode(CleanupChatCompletion.self, from: Data(json.utf8))
            XCTAssertEqual(try response.completeText(), "Complete.")
        }
    }
}

extension TranscriptCleanupPlanTests {
    func testLongPlanningBoundsTokenizerWorkInsteadOfScanningEverySuffix() async throws {
        let text = String(repeating: "Please keep invoice 42 and send the report tomorrow.\n", count: 2_600)
        var traversed = 0
        var largest = 0
        let chunks = try await TranscriptCleanupPlan.chunks(text) { candidate in
            traversed += candidate.utf8.count
            largest = max(largest, candidate.utf8.count)
            return candidate.utf8.count <= 4_096
        }
        XCTAssertEqual(chunks.map(\.original).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.original.utf8.count <= 4_096 })
        XCTAssertLessThanOrEqual(largest, 8_192)
        XCTAssertLessThan(traversed, text.utf8.count * 20, "Sizing must scale with chunks, not all remaining suffixes")
    }

    func testNonmonotonicSelectedBoundariesStayWithinBackendBudget() async throws {
        let text = "Alpha. Beta. Gamma. Delta. Epsilon. Zeta."
        let fits: (String) async -> Bool = { $0.count <= 23 && !$0.hasSuffix("Beta. ") }
        let chunks = try await TranscriptCleanupPlan.chunks(text, fits: fits)
        XCTAssertEqual(chunks.map(\.original).joined(), text)
        for chunk in chunks { let accepted = await fits(chunk.original); XCTAssertTrue(accepted) }
    }
}

import Foundation
import XCTest
@testable import Dictate_Anywhere

private actor CleanupSchedulingProbe {
    enum Mode { case reordered, failure, waiting }
    private let mode: Mode
    private let started: @Sendable () -> Void
    private(set) var count = 0
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var cancellations = 0

    init(mode: Mode, started: @escaping @Sendable () -> Void = {}) {
        self.mode = mode
        self.started = started
    }

    func generate(_ text: String) async throws -> String {
        count += 1
        let index = count
        active += 1
        peak = max(peak, active)
        started()
        defer { active -= 1 }
        do {
            switch mode {
            case .reordered:
                try await Task.sleep(for: .milliseconds(index == 1 ? 80 : 5))
            case .failure where index == 1:
                try await Task.sleep(for: .milliseconds(40))
                throw URLError(.badServerResponse)
            case .failure, .waiting:
                try await Task.sleep(for: .seconds(30))
            }
        } catch is CancellationError {
            cancellations += 1
            throw CancellationError()
        }
        let data = try JSONSerialization.data(withJSONObject: ["action": "pasteCleanedText", "text": text])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class RemoteCleanupConcurrencyTests: XCTestCase {
    private let text = (1...30).map { "Keep invoice \($0) unchanged and send the report tomorrow.\n\n" }.joined()

    func testBoundedRequestsCompleteOutOfOrderButPreserveAllTextAndSeparators() async throws {
        let probe = CleanupSchedulingProbe(mode: .reordered)
        let output = try await RemoteCleanupProcessing.process(text: text, instructions: "Correct punctuation.", vocabulary: [],
            context: nil, contextLength: 1_500, maximumConcurrentRequests: 20) { try await probe.generate($0) }
        XCTAssertEqual(output, text)
        let peak = await probe.peak
        let count = await probe.count
        XCTAssertEqual(peak, 2, "The hard limit protects provider quotas even with a larger requested limit")
        XCTAssertGreaterThan(count, 2)
    }

    func testLocalDefaultRemainsSerialAndSingleChunkUsesOneRequest() async throws {
        for input in [text, "Keep invoice 42."] {
            let probe = CleanupSchedulingProbe(mode: .reordered)
            let output = try await RemoteCleanupProcessing.process(text: input, instructions: "Correct punctuation.", vocabulary: [],
                context: nil, contextLength: 1_500) { try await probe.generate($0) }
            XCTAssertEqual(output, input)
            let peak = await probe.peak
            XCTAssertEqual(peak, 1)
            if input != text {
                let count = await probe.count
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testFailureCancelsSiblingAndCannotReturnPartialCleanupOrStartQueuedChunks() async throws {
        let probe = CleanupSchedulingProbe(mode: .failure)
        do {
            _ = try await RemoteCleanupProcessing.process(text: text, instructions: "Correct punctuation.", vocabulary: [],
                context: nil, contextLength: 1_500, maximumConcurrentRequests: 2) { try await probe.generate($0) }
            XCTFail("Partial cleanup must never escape a failed request")
        } catch { XCTAssertTrue(error is URLError) }
        let count = await probe.count
        let cancelled = await probe.cancellations
        let active = await probe.active
        XCTAssertEqual(count, 2)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(active, 0, "All request lifetimes must end before the failed operation returns")
    }

    func testCancellationJoinsBothInFlightRequestsWithoutStartingMore() async throws {
        let started = expectation(description: "two requests started")
        started.expectedFulfillmentCount = 2
        let probe = CleanupSchedulingProbe(mode: .waiting, started: { started.fulfill() })
        let input = text
        let task = Task {
            try await RemoteCleanupProcessing.process(text: input, instructions: "Correct punctuation.", vocabulary: [],
                context: nil, contextLength: 1_500, maximumConcurrentRequests: 2) { try await probe.generate($0) }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled cleanup must not produce an output") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await probe.count
        let cancelled = await probe.cancellations
        let active = await probe.active
        XCTAssertEqual(count, 2)
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(active, 0)
    }
}

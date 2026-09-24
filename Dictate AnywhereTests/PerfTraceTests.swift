import XCTest
@testable import Dictate_Anywhere

final class PerfTraceTests: XCTestCase {
    func testSyncMeasureReturnsValue() {
        let value = PerfTrace.measure("test.sync") { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSyncMeasureRethrows() {
        struct Probe: Error {}
        XCTAssertThrowsError(try PerfTrace.measure("test.syncThrow") { throw Probe() })
    }

    func testAsyncMeasureReturnsValue() async {
        let value = await PerfTrace.measure("test.async") {
            try? await Task.sleep(for: .milliseconds(1))
            return "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    func testErrorOutcomesIncludeURLSessionCancellation() {
        struct Probe: Error {}
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: CancellationError())), "cancelled")
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: URLError(.cancelled))), "cancelled")
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: Probe())), "failed")
    }

    func testBeginEndIsIdempotent() {
        let interval = PerfTrace.begin("test.manual")
        XCTAssertTrue(interval.end())
        XCTAssertFalse(interval.end())
    }

    func testBeginEndWithCustomOutcomeDoesNotCrash() {
        let interval = PerfTrace.begin("test.manualOutcome")
        interval.end(outcome: "cancelled")
    }

    func testEventDoesNotCrash() {
        PerfTrace.event("test.event")
    }

    func testKillSwitchIsReadFromLaunchEnvironment() {
        XCTAssertTrue(PerfTrace.isEnabled(in: [:]))
        XCTAssertTrue(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "1"]))
        XCTAssertFalse(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "0"]))
        XCTAssertEqual(PerfTrace.isEnabled, PerfTrace.isEnabled(in: ProcessInfo.processInfo.environment))
    }

    func testSessionMetadataMergesAndClears() {
        let original = PerfTraceSessionMetadata(labels: ["session_id": "first", "engine": "parakeet"])
        let updated = original.merging(["session_id": "second", "model": "test-model"])
        XCTAssertEqual(original.logFields, "engine=parakeet session_id=first")
        XCTAssertEqual(updated.logFields, "engine=parakeet model=test-model session_id=second")
        PerfTrace.setSessionMetadata(["session_id": "test", "engine": "parakeet"])
        PerfTrace.updateSessionMetadata(["model": "test-model"])
        PerfTrace.clearSessionMetadata()
    }

    func testRequestCountsStayOnTheirInterval() {
        let interval = PerfTrace.begin("test.request", counts: ["input_samples": 16_000])
        interval.recordCounts(["new_samples": 8_000])
        XCTAssertTrue(interval.end(outcome: "completed"))
        interval.recordCounts(["new_samples": 32_000])
        XCTAssertFalse(interval.end())
    }
}

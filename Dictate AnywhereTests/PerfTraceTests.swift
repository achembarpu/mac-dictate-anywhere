import XCTest
@testable import Dictate_Anywhere

final class PerfTraceTests: XCTestCase {
    func testSyncMeasureReturnsValue() throws {
        let value = try PerfTrace.measure("test.sync") { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSyncMeasureRethrows() {
        struct Probe: Error {}
        XCTAssertThrowsError(try PerfTrace.measure("test.syncThrow") { throw Probe() })
    }

    func testAsyncMeasureReturnsValue() async throws {
        let value = try await PerfTrace.measure("test.async") {
            try? await Task.sleep(for: .milliseconds(1))
            return "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    func testBeginEndDoesNotCrash() {
        let interval = PerfTrace.begin("test.manual")
        interval.end()
    }

    func testBeginEndWithCustomOutcomeDoesNotCrash() {
        let interval = PerfTrace.begin("test.manualOutcome")
        interval.end(outcome: "cancelled")
    }

    func testEventDoesNotCrash() {
        PerfTrace.event("test.event")
    }

    func testIsEnabledDefaultsToTrue() {
        // The test host does not set the kill-switch variable.
        XCTAssertTrue(PerfTrace.isEnabled)
    }

    func testKillSwitchDisablesTracing() {
        setenv("DICTATE_ANYWHERE_PERF_TRACE", "0", 1)
        defer { unsetenv("DICTATE_ANYWHERE_PERF_TRACE") }
        XCTAssertFalse(PerfTrace.isEnabled)
    }

    func testKillSwitchRestoresAfterUnset() {
        // Guard: the previous test's defer must have cleaned up.
        XCTAssertNil(ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_PERF_TRACE"])
        XCTAssertTrue(PerfTrace.isEnabled)
    }
}

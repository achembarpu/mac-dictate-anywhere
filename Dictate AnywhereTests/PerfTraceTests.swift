import XCTest
@testable import Dictate_Anywhere

nonisolated private final class TraceSnapshotStorage: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: String] = [:]
}

final class PerfTraceTests: XCTestCase {

    func testBuildDefaultAndLaunchOverride() {
        #if DISTRIBUTION_BUILD
        XCTAssertFalse(PerfTrace.isEnabled(in: [:]))
        #else
        XCTAssertTrue(PerfTrace.isEnabled(in: [:]))
        #endif
        XCTAssertTrue(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "1"]))
        XCTAssertFalse(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "0"]))
        XCTAssertEqual(PerfTrace.isEnabled, PerfTrace.isEnabled(in: ProcessInfo.processInfo.environment))
    }

    func testDisabledIntervalSkipsCountsAndMetadataAndNeverEnds() throws {
        try XCTSkipUnless(!PerfTrace.isEnabled, "Requires disabled tracing")
        var evaluated = false
        func counts() -> [String: Int] {
            evaluated = true
            return ["input_samples": 1]
        }
        let first = PerfTrace.begin("test.disabled", counts: counts())
        let second = PerfTrace.begin("test.disabledOther")
        XCTAssertTrue(first === second)
        first.recordCounts(counts())
        PerfTrace.event("test.disabledEvent", counts: counts())
        PerfTrace.setSessionMetadata(["session_id": { evaluated = true; return "unused" }()])
        PerfTrace.updateSessionMetadata(["engine": { evaluated = true; return "unused" }()])
        first.refreshSessionMetadata()
        XCTAssertFalse(first.end())
        XCTAssertFalse(second.end())
        XCTAssertFalse(evaluated)
    }

    #if DEBUG
    func testEnabledIntervalsSnapshotSessionAndRefreshOnlyWhenRequested() throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled tracing")
        PerfTrace.setSessionMetadata(["session_id": "first", "engine": "old"])
        defer { PerfTrace.clearSessionMetadata(); PerfTrace.onIntervalCompleted = nil }
        let old = PerfTrace.begin("test.oldSession")
        let refreshed = PerfTrace.begin("test.refreshedSession")
        PerfTrace.setSessionMetadata(["session_id": "second", "engine": "new"])
        refreshed.refreshSessionMetadata()
        let snapshots = TraceSnapshotStorage()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            snapshots.lock.withLock { snapshots.values[name] = metadata }
        }
        XCTAssertTrue(old.end())
        XCTAssertTrue(refreshed.end())
        PerfTrace.setSessionMetadata(["session_id": "third"])
        refreshed.refreshSessionMetadata()
        XCTAssertFalse(refreshed.end())
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.oldSession"]?.contains("session_id=first") == true })
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.refreshedSession"]?.contains("session_id=second") == true })
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.refreshedSession"]?.contains("engine=new") == true })
    }
    #endif
}

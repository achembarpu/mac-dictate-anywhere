import XCTest
@testable import Dictate_Anywhere

@MainActor
final class EOUCleanupDraftSessionTests: XCTestCase {
    private func configuration(revision: Int = 0, modelRevision: Int = 0) -> EOUCleanupDraftSession.Configuration {
        .init(modelURL: URL(fileURLWithPath: "/unused/model.gguf"), modelRevision: modelRevision,
              settingsRevision: revision, styling: .semiFormal, structure: .prose, context: "general")
    }

    // Protects the compute budget against fast ASR revisions, and verifies that
    // a trailing request uses the newest observed source rather than a queue.
    func testSparseScheduleCoalescesRevisionsAndBoundsContinuousSpeech() async {
        var requests: [String] = []
        let config = configuration()
        let session = EOUCleanupDraftSession(now: 0) { source, _ in
            requests.append(source)
            return source
        }
        for tick in 0...2_000 {
            let now = Double(tick) / 10
            // Continuous text never reaches the stability threshold; periodic
            // opportunities still occur without knowledge of recording length.
            session.update(source: "revision \(tick)", configuration: config, now: now)
            await session.join()
        }
        XCTAssertEqual(requests.first, "revision 100")
        XCTAssertEqual(requests.last, "revision 1500")
        XCTAssertEqual(requests.count, 15)
        session.cancel()
        await session.join()

        var stableSources: [String] = []
        let stable = EOUCleanupDraftSession(now: 0) { source, _ in
            stableSources.append(source)
            return source
        }
        stable.update(source: "old", configuration: config, now: 0)
        stable.update(source: "latest", configuration: config, now: 7)
        stable.update(source: "latest", configuration: config, now: 8)
        await stable.join()
        for tick in 81...160 {
            stable.update(source: "latest", configuration: config, now: Double(tick) / 10)
        }
        XCTAssertEqual(stableSources, ["latest"], "Unchanged text must not be cleaned repeatedly")
        stable.cancel()
        await stable.join()
    }

    // A native decode may ignore cancellation until its current call returns.
    // Cancellation must retain ownership, reject its late result, and join it.
    func testCancellationJoinsUncooperativeWorkAndDoesNotPublishIt() async {
        let probe = DraftProbe()
        let started = expectation(description: "request started")
        probe.onStart = { started.fulfill() }
        let session = EOUCleanupDraftSession(now: 0, process: probe.process)
        session.update(source: "preview", configuration: configuration(), now: 0)
        session.update(source: "preview", configuration: configuration(), now: 8)
        await fulfillment(of: [started], timeout: 2)
        session.cancel()
        var joined = false
        let joining = Task { await session.join(); joined = true }
        await Task.yield()
        XCTAssertFalse(joined)
        probe.finish("late output")
        await joining.value
        XCTAssertTrue(joined)
        XCTAssertNil(session.freeze())
        session.update(source: "next session", configuration: configuration(), now: 40)
        XCTAssertEqual(probe.sources, ["preview"])
    }

    // Stop may reuse an older completed draft, but never a request finishing
    // after Stop. Full final ASR is separately verified by the real-model test.
    func testStopFreezesCompletedOutputBeforeJoiningTheTrailingRequest() async {
        let probe = DraftProbe()
        let session = EOUCleanupDraftSession(now: 0, process: probe.process)
        let config = configuration()
        let first = expectation(description: "first started")
        probe.onStart = { first.fulfill() }
        session.update(source: "partial", configuration: config, now: 0)
        session.update(source: "partial", configuration: config, now: 8)
        await fulfillment(of: [first], timeout: 2)
        probe.finish("completed draft")
        await session.join()
        let second = expectation(description: "trailing started")
        probe.onStart = { second.fulfill() }
        session.update(source: "partial plus tail", configuration: config, now: 15)
        session.update(source: "partial plus tail", configuration: config, now: 16)
        await fulfillment(of: [second], timeout: 2)
        let candidate = session.freeze()
        probe.finish("too late")
        await session.join()
        XCTAssertEqual(candidate?.output(matching: config), "completed draft")
        XCTAssertNil(candidate?.output(matching: configuration(revision: 1)))
        XCTAssertNil(candidate?.output(matching: configuration(modelRevision: 1)))
    }

    // Changing controls must reject both a cached result and a late old request;
    // a replacement cannot overlap that request or replenish the launch budget.
    func testControlChangesCancelOldWorkAndKeepOnlyTheNewConfiguration() async {
        let probe = DraftProbe()
        let session = EOUCleanupDraftSession(now: 0, process: probe.process)
        let old = configuration()
        let new = configuration(revision: 1)
        let started = expectation(description: "old request started")
        probe.onStart = { started.fulfill() }
        session.update(source: "preview", configuration: old, now: 0)
        session.update(source: "preview", configuration: old, now: 8)
        await fulfillment(of: [started], timeout: 2)
        session.update(source: "preview", configuration: new, now: 16)
        XCTAssertEqual(probe.sources.count, 1)
        probe.finish("old controls")
        await session.join()
        let replacement = expectation(description: "replacement started")
        probe.onStart = { replacement.fulfill() }
        session.update(source: "newest preview", configuration: new, now: 17)
        session.update(source: "newest preview", configuration: new, now: 18)
        await fulfillment(of: [replacement], timeout: 2)
        probe.finish("new controls")
        await session.join()
        let candidate = session.freeze()
        XCTAssertEqual(probe.sources, ["preview", "newest preview"])
        XCTAssertEqual(candidate?.output(matching: new), "new controls")
        XCTAssertNil(candidate?.output(matching: old))
    }

    // This includes off/on between polls: matching visible controls must not
    // resurrect work produced before the user disabled the setting.
    func testDisablingMidRecordingCancelsWorkAndInvalidatesDisableReenableDrafts() async {
        let settings = Settings.shared
        let saved = settings.s1MiniEOUFasterFinishEnabled
        defer { settings.s1MiniEOUFasterFinishEnabled = saved }
        settings.s1MiniEOUFasterFinishEnabled = true
        let old = configuration(revision: settings.s1MiniDraftRevision)
        let probe = DraftProbe()
        let session = EOUCleanupDraftSession(now: 0, process: probe.process)
        let started = expectation(description: "request started")
        probe.onStart = { started.fulfill() }
        session.update(source: "preview", configuration: old, now: 0)
        session.update(source: "preview", configuration: old, now: 8)
        await fulfillment(of: [started], timeout: 2)
        settings.s1MiniEOUFasterFinishEnabled = false
        session.update(source: "preview", configuration: nil, now: 9)
        probe.finish("disabled result")
        await session.join()
        for now in [20.0, 40.0, 80.0] {
            session.update(source: "new tail", configuration: nil, now: now)
        }
        XCTAssertEqual(probe.sources.count, 1)
        XCTAssertNil(session.freeze())

        let cached = EOUCleanupDraftSession(now: 0) { _, _ in "cached output" }
        cached.update(source: "preview", configuration: old, now: 0)
        cached.update(source: "preview", configuration: old, now: 8)
        await cached.join()
        settings.s1MiniEOUFasterFinishEnabled = true
        let current = configuration(revision: settings.s1MiniDraftRevision)
        XCTAssertNil(cached.freeze()?.output(matching: current))
    }
}

@MainActor
private final class DraftProbe {
    var sources: [String] = []
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<String, Never>?

    func process(_ source: String, _ configuration: EOUCleanupDraftSession.Configuration) async throws -> String {
        sources.append(source)
        return await withCheckedContinuation {
            continuation = $0
            onStart?()
        }
    }

    func finish(_ output: String) {
        continuation?.resume(returning: output)
        continuation = nil
    }
}

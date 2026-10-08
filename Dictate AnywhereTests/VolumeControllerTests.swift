import XCTest
@testable import Dictate_Anywhere

#if DEBUG
@MainActor
final class VolumeControllerTests: XCTestCase {
    func testFinalizationConsumesSettleIntervalWithoutEarlyRestoration() async {
        var clock = ContinuousClock.now
        var waits: [Duration] = []
        let volume = VolumeController(now: { clock }, waitForRouteSettle: { waits.append($0) })
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        clock = clock.advanced(by: .milliseconds(300))
        XCTAssertTrue(volume.hasOutputStateToRestore, "Capture stop must not restore before delivery")
        await volume.restoreAfterRecordingWithSettle()
        XCTAssertTrue(waits.isEmpty)
        XCTAssertFalse(volume.hasOutputStateToRestore)
    }

    func testShortFinalizationWaitsOnlyForRemainingInterval() async {
        var clock = ContinuousClock.now
        var waits: [Duration] = []
        let volume = VolumeController(now: { clock }, waitForRouteSettle: { waits.append($0) })
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        clock = clock.advanced(by: .milliseconds(75))
        volume.recordCaptureStopped()
        await volume.restoreAfterRecordingWithSettle()
        XCTAssertEqual(waits, [.milliseconds(125)], "Repeated stop must not restart the interval")
        XCTAssertFalse(volume.hasOutputStateToRestore)
    }

    func testRestorationResetsDeadlineForTheNextRecording() async {
        var clock = ContinuousClock.now
        var waits: [Duration] = []
        let volume = VolumeController(now: { clock }, waitForRouteSettle: { waits.append($0) })
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        clock = clock.advanced(by: .seconds(1))
        volume.restoreAfterRecording()
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        await volume.restoreAfterRecordingWithSettle()
        XCTAssertEqual(waits, [.milliseconds(200)])
    }

    func testBypassedOrAlreadyMutedOutputNeedsNoSettle() async {
        var waits: [Duration] = []
        let volume = VolumeController(waitForRouteSettle: { waits.append($0) })
        volume.recordCaptureStopped()
        await volume.restoreAfterRecordingWithSettle()
        volume.installOutputMuteStateForTesting(didMuteForRecording: false)
        volume.recordCaptureStopped()
        await volume.restoreAfterRecordingWithSettle()
        XCTAssertTrue(waits.isEmpty)
    }

    func testSuspendedRestoreCannotChangeANewerRecording() async {
        let waiting = expectation(description: "restore suspended")
        var release: CheckedContinuation<Void, Never>?
        let volume = VolumeController(waitForRouteSettle: { _ in
            await withCheckedContinuation { release = $0; waiting.fulfill() }
        })
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        let restoring = Task { await volume.restoreAfterRecordingWithSettle() }
        await fulfillment(of: [waiting], timeout: 5)
        volume.restoreAfterRecording()
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        release?.resume()
        await restoring.value
        XCTAssertTrue(volume.hasOutputStateToRestore)
        volume.restoreAfterRecording()
    }

    func testCancellationStillRestoresOwnedOutput() async {
        let volume = VolumeController()
        volume.installOutputMuteStateForTesting(didMuteForRecording: true)
        volume.recordCaptureStopped()
        let restoring = Task { await volume.restoreAfterRecordingWithSettle() }
        restoring.cancel()
        await restoring.value
        XCTAssertFalse(volume.hasOutputStateToRestore)
    }
}
#endif

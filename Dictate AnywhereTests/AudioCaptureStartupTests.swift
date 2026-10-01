import XCTest
import AVFoundation
@testable import Dictate_Anywhere

final class AudioCaptureStartupTests: XCTestCase {
    func testCancellationDuringRestartGapDoesNotConstructCapture() async {
        let gate = AudioCaptureRestartGate(minimumGap: .seconds(5))
        gate.recordStop()
        let cancellation = AudioCaptureStartupCancellation()
        let constructed = LockedValue(false)
        let startedAt = ContinuousClock.now
        let startup = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 1, queue: DispatchQueue(label: "AudioCaptureStartupTests.cancelGap"),
                cancellation: cancellation, restartGate: gate
            ) {
                constructed.set(true)
                return TestAudioCaptureController()
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        cancellation.cancel()
        do {
            _ = try await startup.value
            XCTFail("Expected cancellation during the restart gap")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(constructed.value)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    }

    func testTaskCancellationDuringRestartGapDoesNotConstructCapture() async {
        let gate = AudioCaptureRestartGate(minimumGap: .seconds(5))
        gate.recordStop()
        let constructed = LockedValue(false)
        let startup = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 1, queue: DispatchQueue(label: "AudioCaptureStartupTests.cancelTask"),
                cancellation: AudioCaptureStartupCancellation(), restartGate: gate
            ) {
                constructed.set(true)
                return TestAudioCaptureController()
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        startup.cancel()
        do {
            _ = try await startup.value
            XCTFail("Expected task cancellation during the restart gap")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(constructed.value)
    }

    func testLateControllerStopRecordsRestartGapBeforeQueuedCaptureIsCreated() async throws {
        let queue = DispatchQueue(label: "AudioCaptureStartupTests.lateStop")
        let releaseFactory = DispatchSemaphore(value: 0)
        let factoryStarted = expectation(description: "first factory started")
        let stopped = expectation(description: "late stop recorded")
        let gate = AudioCaptureRestartGate(minimumGap: .milliseconds(200))
        let firstController = TestAudioCaptureController()
        let first = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 0.05, queue: queue, cancellation: AudioCaptureStartupCancellation(),
                restartGate: gate, onLateControllerStopped: {
                    gate.recordStop()
                    stopped.fulfill()
                }
            ) {
                factoryStarted.fulfill()
                _ = releaseFactory.wait(timeout: .now() + 3)
                return firstController
            }
        }
        defer { releaseFactory.signal() }
        await fulfillment(of: [factoryStarted], timeout: 2)
        do {
            _ = try await first.value
            XCTFail("Expected the blocked first capture to time out")
        } catch let error as TranscriptionError {
            guard case .audioEngineSetupTimedOut = error else { throw error }
        }

        let prematureCapture = LockedValue(false)
        let second = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 2, queue: queue, cancellation: AudioCaptureStartupCancellation(),
                restartGate: gate
            ) {
                prematureCapture.set(gate.remaining() > .zero)
                return TestAudioCaptureController()
            }
        }
        // Give the second startup time to enqueue behind the stalled factory.
        try await Task.sleep(for: .milliseconds(30))
        releaseFactory.signal()
        await fulfillment(of: [stopped], timeout: 2)
        let controller = try await second.value
        controller.stop()
        XCTAssertTrue(firstController.wasStopped)
        XCTAssertFalse(prematureCapture.value, "Construction must honor a stop recorded while queued")
    }

    #if DEBUG
    func testRealAudioRapidRestartSmoke() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_AUDIO_CAPTURE_SMOKE"] == "1",
            "Opt in with RUN_AUDIO_CAPTURE_SMOKE=1 for the microphone hardware test"
        )
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "The Debug app needs existing microphone permission"
        )
        let engine = ParakeetEngine()
        for iteration in 0..<3 {
            let samplesSeen = expectation(description: "capture \(iteration) produced audio samples")
            let received = LockedValue(false)
            // Different queues exercise the shared gate used when changing engines.
            let capture = try await startAudioCaptureOffMainActor(
                timeout: 5, queue: DispatchQueue(label: "AudioCaptureStartupTests.hardware.\(iteration)"),
                cancellation: AudioCaptureStartupCancellation(),
                onLateControllerStopped: { AudioCaptureRestartGate.shared.recordStop() }
            ) {
                try makeAudioCaptureController(deviceID: nil, usesExplicitMicrophoneSelection: false) { samples in
                    if !samples.isEmpty, !received.value {
                        received.set(true)
                        samplesSeen.fulfill()
                    }
                }
            }
            await fulfillment(of: [samplesSeen], timeout: 3)
            engine.installAudioCaptureControllerForTesting(capture)
            await engine.stopAudioCapture()
        }
        await engine.cancel()
    }

    func testAudioCaptureStartupHonorsPendingRestartGap() async throws {
        let gate = AudioCaptureRestartGate(minimumGap: .milliseconds(250))
        gate.recordStop()
        let didSettle = LockedValue(false)
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "audio.settle" { didSettle.set(true) }
        }
        defer { PerfTrace.onIntervalCompleted = nil }

        let controller = TestAudioCaptureController()
        let result = try await startAudioCaptureOffMainActor(
            timeout: 1,
            queue: DispatchQueue(label: "AudioCaptureStartupTests.restartGap"),
            cancellation: AudioCaptureStartupCancellation(),
            restartGate: gate
        ) { controller }

        XCTAssertTrue(result === controller)
        XCTAssertTrue(didSettle.value)
    }
    #endif

    func testAudioCaptureStartupRunsFactoryOffMainThread() async throws {
        let controller = TestAudioCaptureController()
        let threadState = LockedValue(true)

        let result = try await startAudioCaptureOffMainActor(
            timeout: 1,
            queue: DispatchQueue(label: "AudioCaptureStartupTests.success"),
            cancellation: AudioCaptureStartupCancellation()
        ) {
            threadState.set(Thread.isMainThread)
            return controller
        }

        XCTAssertTrue(result === controller)
        XCTAssertFalse(threadState.value)
        XCTAssertFalse(controller.wasStopped)
    }

    func testStalledAudioCaptureStartupTimesOutAndStopsLateController() async {
        let controllerStopped = expectation(description: "late audio controller stopped")
        let controller = TestAudioCaptureController {
            controllerStopped.fulfill()
        }
        let startedAt = ContinuousClock.now

        do {
            _ = try await startAudioCaptureOffMainActor(
                timeout: 0.05,
                queue: DispatchQueue(label: "AudioCaptureStartupTests.timeout"),
                cancellation: AudioCaptureStartupCancellation()
            ) {
                Thread.sleep(forTimeInterval: 1)
                return controller
            }
            XCTFail("Expected audio capture startup to time out")
        } catch let error as TranscriptionError {
            guard case .audioEngineSetupTimedOut = error else {
                XCTFail("Unexpected transcription error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(500))
        await fulfillment(of: [controllerStopped], timeout: 2)
        XCTAssertTrue(controller.wasStopped)
    }

    func testCancelledAudioCaptureStartupReturnsImmediatelyAndStopsLateController() async {
        let controllerStopped = expectation(description: "cancelled late audio controller stopped")
        let controller = TestAudioCaptureController {
            controllerStopped.fulfill()
        }
        let cancellation = AudioCaptureStartupCancellation()
        let startedAt = ContinuousClock.now

        let startupTask = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 2,
                queue: DispatchQueue(label: "AudioCaptureStartupTests.cancelled"),
                cancellation: cancellation
            ) {
                Thread.sleep(forTimeInterval: 1)
                return controller
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        cancellation.cancel()

        do {
            _ = try await startupTask.value
            XCTFail("Expected cancelled audio capture startup to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(500))
        await fulfillment(of: [controllerStopped], timeout: 2)
        XCTAssertTrue(controller.wasStopped)
    }
}

private final class TestAudioCaptureController: @unchecked Sendable, AudioCaptureController {
    private let lock = NSLock()
    private let onStop: () -> Void
    private var stopped = false

    init(onStop: @escaping () -> Void = {}) {
        self.onStop = onStop
    }

    var wasStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        let shouldNotify = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldNotify {
            onStop()
        }
    }
}

nonisolated private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock {
            storage = value
        }
    }
}

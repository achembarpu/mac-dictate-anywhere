//
//  AudioCaptureStartup.swift
//  Dictate Anywhere
//
//  Keeps potentially blocking CoreAudio startup work off the main actor.
//

import Foundation

nonisolated private final class AudioCaptureFactoryBox: @unchecked Sendable {
    let makeController: () throws -> AudioCaptureController
    let onLateControllerStopped: @Sendable () -> Void

    init(
        makeController: @escaping () throws -> AudioCaptureController,
        onLateControllerStopped: @escaping @Sendable () -> Void
    ) {
        self.makeController = makeController
        self.onLateControllerStopped = onLateControllerStopped
    }

    func createWhenSettled(
        on queue: DispatchQueue,
        resolution: AudioCaptureStartupResolution,
        restartGate: AudioCaptureRestartGate
    ) {
        guard resolution.isPending else { return }
        // A previous startup can finish late on this same queue after the
        // caller's initial wait. Recheck at the actual construction boundary.
        let delay = restartGate.remaining()
        if delay > .zero {
            let parts = delay.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            let trace = PerfTrace.begin("audio.settle")
            queue.asyncAfter(deadline: .now() + seconds) {
                trace.end(outcome: resolution.isPending ? "completed" : "cancelled")
                self.createWhenSettled(on: queue, resolution: resolution, restartGate: restartGate)
            }
            return
        }
        do {
            let controller = try PerfTrace.measure("audio.controllerCreate") { try makeController() }
            if !resolution.resume(with: .success(controller)) {
                controller.stop()
                onLateControllerStopped()
            }
        } catch {
            resolution.resume(with: .failure(error))
        }
    }
}

nonisolated private final class AudioCaptureStartupResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AudioCaptureController, Error>?

    init(continuation: CheckedContinuation<AudioCaptureController, Error>) {
        self.continuation = continuation
    }

    var isPending: Bool {
        lock.withLock { continuation != nil }
    }

    /// Returns false when another result (normally the timeout) already won.
    @discardableResult
    func resume(with result: Result<AudioCaptureController, Error>) -> Bool {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

nonisolated final class AudioCaptureStartupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var cancellationHandler: (@Sendable () -> Void)?

    /// Returns false when cancellation already happened before registration.
    func register(_ handler: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            cancellationHandler = handler
            return true
        }
    }

    func cancel() {
        let handler = lock.withLock {
            guard !isCancelled else { return nil as (@Sendable () -> Void)? }
            isCancelled = true
            let pending = cancellationHandler
            cancellationHandler = nil
            return pending
        }
        handler?()
    }
}

/// Parakeet capture teardown needs a short HAL gap before the next capture.
/// All engines start through the helper below, so a rapid engine switch also
/// honors the gap without delaying the completed dictation.
nonisolated final class AudioCaptureRestartGate: @unchecked Sendable {
    static let shared = AudioCaptureRestartGate()

    private let lock = NSLock()
    private let minimumGap: Duration
    private var lastStop: ContinuousClock.Instant?

    init(minimumGap: Duration = .milliseconds(120)) {
        self.minimumGap = minimumGap
    }

    func recordStop(at instant: ContinuousClock.Instant = .now) {
        lock.withLock {
            // Calls from different teardown queues must never move the
            // deadline backwards if an earlier stop is reported late.
            if let lastStop, instant <= lastStop { return }
            lastStop = instant
        }
    }

    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        lock.withLock {
            guard let lastStop else { return .zero }
            return max(.zero, now.duration(to: lastStop + minimumGap))
        }
    }

    func waitIfNeeded() async throws {
        while true {
            try Task.checkCancellation()
            let delay = remaining()
            guard delay > .zero else { return }
            let trace = PerfTrace.begin("audio.settle")
            do {
                try await Task.sleep(for: delay)
                trace.end()
            } catch {
                trace.end(outcome: "cancelled")
                throw error
            }
        }
    }
}

/// Runs audio capture construction away from the main actor and bounds how long
/// the caller waits for CoreAudio. A controller that arrives after the timeout
/// is stopped immediately so it cannot become an orphaned microphone session.
nonisolated func startAudioCaptureOffMainActor(
    timeout: TimeInterval,
    queue: DispatchQueue,
    cancellation: AudioCaptureStartupCancellation,
    restartGate: AudioCaptureRestartGate = .shared,
    onLateControllerStopped: @escaping @Sendable () -> Void = {},
    makeController: @escaping () throws -> AudioCaptureController
) async throws -> AudioCaptureController {
    try await withTaskCancellationHandler {
        let restartWait = Task { try await restartGate.waitIfNeeded() }
        guard cancellation.register({ restartWait.cancel() }) else {
            restartWait.cancel()
            throw CancellationError()
        }
        try await restartWait.value
        let factory = AudioCaptureFactoryBox(
            makeController: makeController, onLateControllerStopped: onLateControllerStopped
        )

        return try await PerfTrace.measure("audio.controllerWait") {
            try await withCheckedThrowingContinuation { continuation in
                let resolution = AudioCaptureStartupResolution(continuation: continuation)
                guard cancellation.register({
                    resolution.resume(with: .failure(CancellationError()))
                }) else {
                    resolution.resume(with: .failure(CancellationError()))
                    return
                }

                queue.async {
                    factory.createWhenSettled(on: queue, resolution: resolution, restartGate: restartGate)
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    resolution.resume(with: .failure(TranscriptionError.audioEngineSetupTimedOut))
                }
            }
        }
    } onCancel: {
        cancellation.cancel()
    }
}

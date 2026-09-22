//
//  PerfTrace.swift
//  Dictate Anywhere
//
//  Lightweight hot-path timing instrumentation for future performance work.
//
//  Approach (Apple-recommended, verified against developer documentation):
//  - `OSSignposter` intervals (macOS 12+) make every span visible in
//    Instruments via the os_signpost instrument. Signposts are designed for
//    near-zero overhead, so they stay enabled in all builds.
//  - Matching `Logger` notice lines record interval durations and point
//    events, visible live in Console.app / `log stream` and historically via
//    `log show` (notice persists to disk; info would stay memory-only).
//  - Only static interval names and numeric durations are logged. Audio,
//    transcripts, prompts, file paths, and other user content are never
//    included, keeping the trace privacy-safe by construction.
//  - Disk usage is bounded by the system, not by this helper: logd keeps
//    compressed tracev3 stores under a predefined size quota and purges the
//    oldest entries first. Long recordings may generate repeated STT spans,
//    but traces cannot grow unboundedly.
//
//  Naming convention: "<area>.<phase>", e.g. "app.startup",
//  "stt.modelLoad", "stt.finalize", "cleanup.generate".
//
//  Viewing results:
//  - Instruments: Product > Profile with the Blank template, add the
//    os_signpost instrument, filter subsystem to the app bundle ID.
//  - Console: `log show --predicate 'subsystem == "<bundleID>" AND
//    category == "Performance"' --last 1h`
//
//  Kill switch (both signposts and log lines): launch with
//  `DICTATE_ANYWHERE_PERF_TRACE=0` in the environment.
//
//  Release builds: tracing stays enabled. This is deliberate — improvements
//  must be measured on release-representative builds. Signposts cost
//  ~nothing unless Instruments is recording, and log volume is bounded
//  (static names and durations only, no user content). The kill switch works
//  identically in Release and Debug.
//

import Foundation
import os

/// Central entry point for hot-path timing traces.
///
/// Deliberately actor-independent: every member is `nonisolated` so tracing
/// never forces a hop onto the main actor (or any other executor). This is
/// sound because the shared instances (`String`, `Logger`, `OSSignposter`)
/// are all `Sendable` and the underlying unified logging system is safe for
/// concurrent use.
enum PerfTrace {
    nonisolated private static let subsystem: String =
        Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere"

    nonisolated private static let logger = Logger(subsystem: subsystem, category: "Performance")

    nonisolated private static let signposter = OSSignposter(logger: logger)
    nonisolated private static let disabledSignposter = OSSignposter.disabled

    /// Read once at launch: the documented kill switch is a launch-time
    /// setting, and checking the process environment on every span is costly.
    nonisolated static let isEnabled = isEnabled(in: ProcessInfo.processInfo.environment)

    nonisolated static func isEnabled(in environment: [String: String]) -> Bool {
        environment["DICTATE_ANYWHERE_PERF_TRACE"] != "0"
    }

    /// Measures a synchronous closure. Returns the closure's value.
    @discardableResult
    nonisolated static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let interval = begin(name)
        do {
            let result = try operation()
            interval.end(outcome: "completed")
            return result
        } catch {
            interval.end(outcome: outcome(for: error))
            throw error
        }
    }

    /// Measures an asynchronous closure. Returns the closure's value.
    @discardableResult
    nonisolated static func measure<T>(_ name: StaticString, _ operation: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        do {
            let result = try await operation()
            interval.end(outcome: "completed")
            return result
        } catch {
            interval.end(outcome: outcome(for: error))
            throw error
        }
    }

    nonisolated static func outcome(for error: Error) -> StaticString {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "cancelled"
        }
        return "failed"
    }

    /// Starts a manually-scoped interval. Pair with `end(outcome:)` on the
    /// returned token — `defer { token.end() }` covers every return/throw path.
    /// An early explicit end is safe: subsequent deferred ends are ignored.
    nonisolated static func begin(_ name: StaticString) -> PerfInterval {
        let enabled = isEnabled
        let poster = enabled ? signposter : disabledSignposter
        let state = poster.beginInterval(name, id: poster.makeSignpostID())
        return PerfInterval(
            name: name,
            state: state,
            signposter: poster,
            startTime: ProcessInfo.processInfo.systemUptime,
            enabled: enabled
        )
    }

    /// Marks a single point of interest (e.g. first partial result).
    ///
    /// The matching notice makes the marker available in historical Console
    /// queries too, not only during a live Instruments recording.
    nonisolated static func event(_ name: StaticString) {
        guard isEnabled else { return }
        signposter.emitEvent(name, id: signposter.makeSignpostID())
        logger.notice("trace \(String(describing: name), privacy: .public) event=observed")
    }

    nonisolated fileprivate static func logCompletion(name: StaticString, milliseconds: Int, outcome: StaticString) {
        // Notice (default) level, not info: per Apple, info stays memory-only
        // while notice persists to disk (up to a system storage limit), so
        // historical `log show` queries work with zero configuration.
        logger.notice(
            "trace \(String(describing: name), privacy: .public) duration_ms=\(milliseconds, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
    }
}

/// An in-flight timing interval. Obtain via `PerfTrace.begin(_:)`.
nonisolated final class PerfInterval: @unchecked Sendable {
    private let name: StaticString
    private let state: OSSignpostIntervalState
    private let signposter: OSSignposter
    private let startTime: TimeInterval
    private let enabled: Bool
    private let lock = NSLock()
    private var didEnd = false

    nonisolated fileprivate init(
        name: StaticString,
        state: OSSignpostIntervalState,
        signposter: OSSignposter,
        startTime: TimeInterval,
        enabled: Bool
    ) {
        self.name = name
        self.state = state
        self.signposter = signposter
        self.startTime = startTime
        self.enabled = enabled
    }

    /// Ends the interval, emitting the signpost and a duration log line.
    /// The default "ended" does not claim success for a manually scoped span.
    /// Outcome must be a static literal (e.g. "completed", "cancelled").
    /// Nonisolated so `defer { token.end() }` works from any executor
    /// without hopping.
    @discardableResult
    nonisolated func end(outcome: StaticString = "ended") -> Bool {
        let shouldEnd = lock.withLock { () -> Bool in
            guard !didEnd else { return false }
            didEnd = true
            return true
        }
        guard shouldEnd else { return false }
        let milliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - startTime) * 1_000))
        signposter.endInterval(name, state)
        if enabled {
            PerfTrace.logCompletion(name: name, milliseconds: milliseconds, outcome: outcome)
        }
        return true
    }
}

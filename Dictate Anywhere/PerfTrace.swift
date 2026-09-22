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
//  - A matching `Logger` info line records the duration in milliseconds, so
//    timings are also visible in Console.app and `log show` without profiling.
//  - Only static interval names and numeric durations are logged. Audio,
//    transcripts, prompts, file paths, and other user content are never
//    included, keeping the trace privacy-safe by construction.
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

import Foundation
import os

/// Central entry point for hot-path timing traces.
enum PerfTrace {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere"

    private static let logger = Logger(subsystem: subsystem, category: "Performance")

    private static let signposter = OSSignposter(logger: logger)
    private static let disabledSignposter = OSSignposter.disabled

    /// False when `DICTATE_ANYWHERE_PERF_TRACE=0` is set. Signposts use the
    /// disabled poster and completion lines are skipped.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_PERF_TRACE"] != "0"
    }

    /// Measures a synchronous closure. Returns the closure's value.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try operation()
    }

    /// Measures an asynchronous closure. Returns the closure's value.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ operation: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try await operation()
    }

    /// Starts a manually-scoped interval. Pair with `end(outcome:)` on the
    /// returned token — `defer { token.end() }` covers every return/throw path.
    static func begin(_ name: StaticString) -> PerfInterval {
        let enabled = isEnabled
        let poster = enabled ? signposter : disabledSignposter
        let id = poster.makeSignpostID()
        let state = poster.beginInterval(name, id: id)
        return PerfInterval(
            name: name,
            id: id,
            state: state,
            signposter: poster,
            startTime: CFAbsoluteTimeGetCurrent(),
            enabled: enabled
        )
    }

    /// Marks a single point of interest (e.g. first partial result).
    static func event(_ name: StaticString) {
        guard isEnabled else { return }
        signposter.emitEvent(name, id: signposter.makeSignpostID())
    }

    fileprivate static func logCompletion(name: StaticString, milliseconds: Int, outcome: StaticString) {
        logger.info(
            "trace \(String(describing: name), privacy: .public) duration_ms=\(milliseconds, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
    }
}

/// An in-flight timing interval. Obtain via `PerfTrace.begin(_:)`.
struct PerfInterval: Sendable {
    private let name: StaticString
    private let id: OSSignpostID
    private let state: OSSignpostIntervalState
    private let signposter: OSSignposter
    private let startTime: CFAbsoluteTime
    private let enabled: Bool

    fileprivate init(
        name: StaticString,
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        signposter: OSSignposter,
        startTime: CFAbsoluteTime,
        enabled: Bool
    ) {
        self.name = name
        self.id = id
        self.state = state
        self.signposter = signposter
        self.startTime = startTime
        self.enabled = enabled
    }

    /// Ends the interval, emitting the signpost and a duration log line.
    /// Outcome must be a static literal (e.g. "completed", "cancelled").
    func end(outcome: StaticString = "completed") {
        let milliseconds = max(0, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1_000))
        signposter.endInterval(name, state)
        if enabled {
            PerfTrace.logCompletion(name: name, milliseconds: milliseconds, outcome: outcome)
        }
    }
}

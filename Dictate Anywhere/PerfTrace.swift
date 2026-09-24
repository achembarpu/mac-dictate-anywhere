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
//  - Static trace names, bounded configuration labels, and numeric workload
//    facts are logged. Never pass audio, transcripts, prompts, paths, or
//    target-application identifiers as metadata.
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
//  (no user content). The kill switch works
//  identically in Release and Debug.
//

import Foundation
import Darwin
import os

nonisolated struct PerfTraceSessionMetadata: Sendable {
    let labels: [String: String]
    /// Formatting once per session avoids sorting the same labels on every
    /// streaming interval (roughly one every 80 ms).
    let logFields: String

    init(labels: [String: String]) {
        self.labels = labels
        self.logFields = labels.keys.sorted().compactMap { key in
            guard let value = labels[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: " ")
    }

    func merging(_ updates: [String: String]) -> Self {
        var merged = labels
        merged.merge(updates) { _, new in new }
        return Self(labels: merged)
    }
}

nonisolated private func numericFields(_ counts: [String: Int]) -> String {
    counts.keys.sorted().compactMap { key in
        guard let value = counts[key] else { return nil }
        return "\(key)=\(value)"
    }.joined(separator: " ")
}

private nonisolated final class PerfTraceMetadataStorage: @unchecked Sendable {
    let lock = NSLock()
    var value: PerfTraceSessionMetadata?
}

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
    nonisolated private static let metadataStorage = PerfTraceMetadataStorage()
    nonisolated private static let environmentLabels: [String: String] = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        let device: String
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            device = sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0
                ? String(cString: bytes) : "unknown"
        } else {
            device = "unknown"
        }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return [
            "device": device,
            "os": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "build_configuration": configuration
        ]
    }()

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

    /// Sets privacy-safe labels for the active dictation session. Values must
    /// describe configuration or lifecycle state, never transcript or target
    /// application content.
    nonisolated static func setSessionMetadata(_ labels: [String: String]) {
        metadataStorage.lock.withLock {
            metadataStorage.value = PerfTraceSessionMetadata(labels: environmentLabels.merging(labels) { _, new in new })
        }
    }

    nonisolated static func updateSessionMetadata(_ labels: [String: String]) {
        metadataStorage.lock.withLock {
            metadataStorage.value = metadataStorage.value?.merging(labels)
        }
    }

    nonisolated static func clearSessionMetadata() {
        metadataStorage.lock.withLock { metadataStorage.value = nil }
    }

    nonisolated private static func currentSessionMetadata() -> PerfTraceSessionMetadata? {
        metadataStorage.lock.withLock { metadataStorage.value }
    }

    /// Starts a manually-scoped interval. Pair with `end(outcome:)` on the
    /// returned token — `defer { token.end() }` covers every return/throw path.
    /// An early explicit end is safe: subsequent deferred ends are ignored.
    nonisolated static func begin(_ name: StaticString, counts: [String: Int] = [:]) -> PerfInterval {
        let enabled = isEnabled
        let poster = enabled ? signposter : disabledSignposter
        let state = poster.beginInterval(name, id: poster.makeSignpostID())
        return PerfInterval(
            name: name,
            state: state,
            signposter: poster,
            startTime: ProcessInfo.processInfo.systemUptime,
            enabled: enabled,
            metadata: enabled ? currentSessionMetadata()?.logFields ?? "session_id=none" : "",
            counts: counts
        )
    }

    /// Marks a single point of interest (e.g. first partial result).
    ///
    /// The matching notice makes the marker available in historical Console
    /// queries too, not only during a live Instruments recording.
    nonisolated static func event(_ name: StaticString, counts: [String: Int] = [:]) {
        guard isEnabled else { return }
        signposter.emitEvent(name, id: signposter.makeSignpostID())
        let metadata = currentSessionMetadata()?.logFields ?? "session_id=none"
        let facts = numericFields(counts)
        logger.notice("trace \(String(describing: name), privacy: .public) event=observed \(metadata, privacy: .public) \(facts, privacy: .public)")
    }

    nonisolated fileprivate static func logCompletion(
        name: StaticString, milliseconds: Int, outcome: StaticString, metadata: String, counts: [String: Int]
    ) {
        // Notice (default) level, not info: per Apple, info stays memory-only
        // while notice persists to disk (up to a system storage limit), so
        // historical `log show` queries work with zero configuration.
        let facts = numericFields(counts)
        logger.notice(
            "trace \(String(describing: name), privacy: .public) duration_ms=\(milliseconds, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) \(metadata, privacy: .public) \(facts, privacy: .public)"
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
    private let metadata: String
    private let lock = NSLock()
    private var didEnd = false
    private var counts: [String: Int]

    nonisolated fileprivate init(
        name: StaticString,
        state: OSSignpostIntervalState,
        signposter: OSSignposter,
        startTime: TimeInterval,
        enabled: Bool,
        metadata: String,
        counts: [String: Int]
    ) {
        self.name = name
        self.state = state
        self.signposter = signposter
        self.startTime = startTime
        self.enabled = enabled
        self.metadata = metadata
        self.counts = counts
    }

    /// Attach request-specific numeric facts to this interval, not to the
    /// process-wide session. Call before end; later sessions cannot inherit them.
    nonisolated func recordCounts(_ values: [String: Int]) {
        guard enabled else { return }
        lock.withLock {
            guard !didEnd else { return }
            counts.merge(values) { _, new in new }
        }
    }

    /// Ends the interval, emitting the signpost and a duration log line.
    /// The default "ended" does not claim success for a manually scoped span.
    /// Outcome must be a static literal (e.g. "completed", "cancelled").
    /// Nonisolated so `defer { token.end() }` works from any executor
    /// without hopping.
    @discardableResult
    nonisolated func end(outcome: StaticString = "ended") -> Bool {
        let recordedCounts = lock.withLock { () -> [String: Int]? in
            guard !didEnd else { return nil }
            didEnd = true
            return counts
        }
        guard let recordedCounts else { return false }
        let milliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - startTime) * 1_000))
        signposter.endInterval(name, state)
        if enabled {
            PerfTrace.logCompletion(
                name: name, milliseconds: milliseconds, outcome: outcome,
                metadata: metadata, counts: recordedCounts
            )
        }
        return true
    }
}

import Foundation

/// Shares successful requests for a bounded interval. Failures are retried,
/// refresh discards completed snapshots, and cancelling a consumer leaves shared work alive.
actor TimedRequestCache<Key: Hashable & Sendable, Value: Sendable> {
    // This reference stays private to the actor. It survives eviction/completion
    // so an invalidated, non-cooperative loader cannot return an obsolete result.
    nonisolated private final class Pending {
        let task: Task<Value, Error>
        var invalidated = false

        init(task: Task<Value, Error>) { self.task = task }
    }

    private let lifetime: Duration
    private let capacity: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var values: [Key: (time: ContinuousClock.Instant, value: Value)] = [:]
    private var pending: [Key: Pending] = [:]

    init(lifetime: Duration = .seconds(300), capacity: Int = 8,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.now = now
    }

    func value(for key: Key, refresh: Bool = false,
               load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if refresh { values[key] = nil }
        if let cached = values[key], cached.time.duration(to: now()) < lifetime {
            return cached.value
        }
        if let request = pending[key] {
            let value = try await request.task.value
            try Task.checkCancellation()
            guard !request.invalidated else { throw CancellationError() }
            return value
        }
        let request = Pending(task: Task { try await load() })
        pending[key] = request
        do {
            let value = try await request.task.value
            guard !request.invalidated else { throw CancellationError() }
            values[key] = (now(), value)
            if values.count > capacity,
               let oldest = values.min(by: { $0.value.time < $1.value.time })?.key {
                values[oldest] = nil
            }
            if pending[key] === request { pending[key] = nil }
            try Task.checkCancellation()
            return value
        } catch {
            if pending[key] === request { pending[key] = nil }
            throw error
        }
    }

    func invalidate(_ key: Key) {
        values[key] = nil
        if let request = pending.removeValue(forKey: key) {
            request.invalidated = true
            request.task.cancel()
        }
    }

    func invalidate(where matches: @Sendable (Key) -> Bool) {
        for key in Set(values.keys).union(pending.keys) where matches(key) {
            invalidate(key)
        }
    }
}

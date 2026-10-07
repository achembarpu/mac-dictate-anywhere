import XCTest
import os
@testable import Dictate_Anywhere

final class TimedRequestCacheTests: XCTestCase {
    func testExpiryAndCapacityLimitCompletedSnapshots() async throws {
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = TimedRequestCache<String, Int>(lifetime: .seconds(1), capacity: 1,
                                                    now: { clock.withLock { $0 } })
        let load: @Sendable () async throws -> Int = { calls.withLock { $0 += 1; return $0 } }
        let first = try await cache.value(for: "one", load: load)
        let cached = try await cache.value(for: "one", load: load)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(cached, 1)
        clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
        let expired = try await cache.value(for: "one", load: load)
        XCTAssertEqual(expired, 2)
        clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
        let second = try await cache.value(for: "two", load: load)
        let evicted = try await cache.value(for: "one", load: load)
        XCTAssertEqual(second, 3)
        XCTAssertEqual(evicted, 4)
    }

    func testCancelledConsumerDoesNotPoisonSharedLoad() async throws {
        let started = expectation(description: "loader started")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = TimedRequestCache<String, Int>()
        let load: @Sendable () async throws -> Int = {
            calls.withLock { $0 += 1 }
            started.fulfill()
            try await Task.sleep(for: .milliseconds(50))
            return 42
        }
        let first = Task { try await cache.value(for: "shared", load: load) }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { try await cache.value(for: "shared", load: load) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer returned a value") }
        catch is CancellationError {}
        let result = try await second.value
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testInvalidationRejectsNonCooperativeOldLoad() async throws {
        let started = expectation(description: "old loader started")
        let continuation = OSAllocatedUnfairLock<CheckedContinuation<Int, Never>?>(initialState: nil)
        let cache = TimedRequestCache<String, Int>()
        let old = Task {
            try await cache.value(for: "model") {
                await withCheckedContinuation { resume in
                    continuation.withLock { $0 = resume }
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await cache.invalidate("model")
        let fresh = try await cache.value(for: "model") { 99 }
        XCTAssertEqual(fresh, 99)
        continuation.withLock { resume in resume?.resume(returning: 42); resume = nil }
        do { _ = try await old.value; XCTFail("Invalidated load returned a value") }
        catch is CancellationError {}
        let cached = try await cache.value(for: "model") { 100 }
        XCTAssertEqual(cached, 99)
    }
}

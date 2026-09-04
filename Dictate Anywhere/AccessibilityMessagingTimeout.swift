//
//  AccessibilityMessagingTimeout.swift
//  Dictate Anywhere
//
//  Scoped accessibility messaging timeout.
//

import Foundation

/// Applies an accessibility messaging timeout for the duration of one call and
/// restores the process default afterwards.
///
/// `AXUIElementSetMessagingTimeout` on the system-wide element sets the timeout
/// "globally for this process": every accessibility read the app makes
/// afterwards inherits it, including `TextInserter`'s, which talk to apps that
/// are legitimately slow to answer. Passing 0 resets the global timeout to its
/// default, so a short timeout taken for one lookup has to be given back.
enum AccessibilityMessagingTimeout {
    /// Runs `body` under `seconds`, then restores the process default.
    ///
    /// The restore runs on every exit path, so neither a thrown error nor an
    /// early return can leak the shortened timeout into unrelated work.
    static func withTimeout<T>(
        _ seconds: Float,
        apply: (Float) -> Void,
        during body: () throws -> T
    ) rethrows -> T {
        apply(seconds)
        defer { apply(0) }
        return try body()
    }
}

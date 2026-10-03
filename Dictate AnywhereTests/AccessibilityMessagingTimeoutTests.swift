import XCTest
@testable import Dictate_Anywhere

/// AX messaging timeouts are process-global and must be restored on every exit path.
final class AccessibilityMessagingTimeoutTests: XCTestCase {
    private struct LookupFailure: Error {}

    func testLookupAppliesTimeoutReturnsResultAndRestoresProcessDefault() {
        for location in [CGPoint(x: 12, y: 34), nil] {
            var applied: [Float] = []
            let result = AccessibilityMessagingTimeout.withTimeout(0.25, apply: { applied.append($0) }) {
                XCTAssertEqual(applied, [0.25], "The lookup must run under the bounded timeout")
                return location
            }
            XCTAssertEqual(result, location)
            XCTAssertEqual(applied, [0.25, 0])
        }
    }

    func testRestoresTheProcessDefaultWhenTheBodyThrows() {
        var applied: [Float] = []

        XCTAssertThrowsError(
            try AccessibilityMessagingTimeout.withTimeout(0.25, apply: { applied.append($0) }) {
                throw LookupFailure()
            }
        )

        XCTAssertEqual(applied, [0.25, 0])
    }
}

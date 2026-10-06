import XCTest
@testable import Dictate_Anywhere

final class ModelReadinessTests: XCTestCase {
    func testInstallationAndAvailabilityDoNotClaimPreparedReadiness() {
        for state in [ModelReadiness.notDownloaded, .downloaded, .available, .configured, .needsSetup,
                      .downloading(1), .verifying, .preparing, .failed("Load failed")] {
            XCTAssertFalse(state.isReady)
            XCTAssertNotEqual(state.title, ModelReadiness.ready.title)
        }
        XCTAssertTrue(ModelReadiness.ready.isReady)
    }

    func testFailedPreparationPreservesTheActionableReason() {
        let state = ModelReadiness.failed("The download was interrupted. Try again.")
        XCTAssertEqual(state.detail, "The download was interrupted. Try again.")
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.progress)
    }
}

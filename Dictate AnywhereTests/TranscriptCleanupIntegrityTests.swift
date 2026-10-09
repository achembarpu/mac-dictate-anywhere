import XCTest
@testable import Dictate_Anywhere

final class TranscriptCleanupIntegrityTests: XCTestCase {
    func testNumbersMayBeFormattedButCannotDisappearOrBeDeduplicated() {
        XCTAssertTrue(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "Record 1005. Invoice 4182, cost 12.50.", in: "Record 1,005. Invoice 4,182 costs 12.50."))
        XCTAssertTrue(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "１４ October", in: "October 14"))
        XCTAssertFalse(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "Record 1005. Keep 4182.", in: "Keep 4182."))
        XCTAssertFalse(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "4182, then 4182", in: "4182"))
        XCTAssertFalse(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "12.50", in: "12.05"))
        XCTAssertFalse(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "1.005", in: "1005"))
        XCTAssertFalse(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "12", in: "twelve"))
        XCTAssertTrue(TranscriptCleanupIntegrity.preservesNumericLiterals(from: "No digits.", in: "No digits."))
    }
}

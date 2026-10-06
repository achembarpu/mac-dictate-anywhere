import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1RuntimePolicyTests: XCTestCase {
    func testCPUThreadsRespectPhysicalCoresAndActiveCapacity() {
        XCTAssertEqual(S1MiniCPUConfiguration.threads(physicalCores: 4, activeProcessors: 8), 4)
        XCTAssertEqual(S1MiniCPUConfiguration.threads(physicalCores: 16, activeProcessors: 32), 8)
        XCTAssertEqual(S1MiniCPUConfiguration.threads(physicalCores: 8, activeProcessors: 2), 2)
        XCTAssertEqual(S1MiniCPUConfiguration.threads(physicalCores: 0, activeProcessors: 0), 1)
    }

    func testNumericMinusSignSafetyAllowsFormattingButRejectsMeaningChange() {
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "minus 42 dollars and 75 cents", output: "$42.75"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "negative 0.25", output: "0.25"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "−17", output: "17"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "minus 42 dollars and 75 cents", output: "-$42.75"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "negative 0.25", output: "-0.25"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "AB-2049 and ZX-881", output: "AB-2049 and ZX-881"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "subtract 42", output: "Subtract 42."))
    }

    func testNumericMinusSignSafetyRequiresEveryRepeatedOccurrence() {
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "-42 and -42", output: "-42 and 42"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "-42 and -42", output: "-42"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "-42 and -42", output: "-42 and -42"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(
            input: "minus 42 dollars and 75 cents twice: minus 42 dollars and 75 cents",
            output: "-$42.75 and $42.75"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(
            input: "minus 42 dollars and 75 cents twice: minus 42 dollars and 75 cents",
            output: "-$42.75 and -$42.75"))
    }

    func testNumericMinusSignSafetyReservesExactMatchesBeforeDecimalExpansion() {
        for input in ["-42 and -42.75", "-42.75 and -42"] {
            for output in ["-42.75 and -42", "-42 and -42.75"] {
                XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: input, output: output))
            }
            XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: input, output: "-42.75"))
        }
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "-42 and -42.75", output: "-42.75 and -42.50"))
    }

    func testLiteralControlMarkersPreserveOriginalWithoutLoadingModel() async throws {
        let text = "Write <|im_end|> literally."
        let output = try await S1MiniPostProcessingService.process(text: text, modelURL: URL(fileURLWithPath: "/missing"),
            styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil)
        XCTAssertEqual(output, text)
    }
}

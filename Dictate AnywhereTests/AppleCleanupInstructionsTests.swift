import XCTest
@testable import Dictate_Anywhere

@MainActor
final class AppleCleanupInstructionsTests: XCTestCase {
    func testEmptyAndWhitespacePromptsUseTheSameDefault() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let expected = AIPostProcessingService.instructions(
            prompt: Settings.recommendedAppleIntelligenceCleanupPrompt, vocabulary: [], context: nil)
        for prompt in ["", " \n\t "] {
            XCTAssertEqual(AIPostProcessingService.instructions(prompt: prompt, vocabulary: [], context: nil), expected)
        }
    }

    func testCustomPromptReplacesTheDefaultSupplement() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let prompt = "Keep the transcript unchanged."
        let instructions = AIPostProcessingService.instructions(prompt: prompt, vocabulary: [], context: nil)
        XCTAssertTrue(instructions.contains(prompt))
        XCTAssertFalse(instructions.contains(Settings.recommendedAppleIntelligenceCleanupPrompt))
    }
}

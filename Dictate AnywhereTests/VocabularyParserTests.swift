import XCTest
@testable import Dictate_Anywhere

final class VocabularyParserTests: XCTestCase {
    func testMixedSeparatorsTrimAndDeduplicateWhilePreservingOrder() {
        let input = "  Parakeet, Ollama\n你好，世界、Parakeet, Ollama, FluidAudio  "
        XCTAssertEqual(VocabularyInputParser.terms(from: input, existingTerms: ["Ollama"]),
            ["Parakeet", "你好", "世界", "FluidAudio"])
    }

    func testEmptyBlankOrAlreadyKnownInputAddsNothing() {
        for input in ["", " , ,\n，、", "Parakeet, Parakeet"] {
            XCTAssertEqual(VocabularyInputParser.terms(from: input, existingTerms: ["Parakeet"]), [],
                input.debugDescription)
        }
    }
}

import XCTest
@testable import Dictate_Anywhere

/// Pause segmentation preserves disjoint audio. Joining must never deduplicate speech.
final class MergeTranscriptsTests: XCTestCase {
    func testLatinAndMixedChunkBoundariesKeepWordSpacing() {
        let fixtures = [
            ("hello world", "how are you", "hello world how are you"),
            ("我要去", "Apple Park", "我要去 Apple Park"),
            ("he said", "「你好」", "he said 「你好」"),
            ("he said「", "你好", "he said「 你好"),
            ("你好 world", "你好", "你好 world 你好"),
            ("hello.", "你好", "hello. 你好"),
        ]
        for (base, addition, expected) in fixtures {
            XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: base, addition: addition), expected,
                "Boundary: \(base.debugDescription) + \(addition.debugDescription)")
        }
    }

    func testCJKPunctuationAttachesWithoutIntroducingSpaces() {
        let fixtures = [
            ("今天天气很好", "我们去公园吧", "今天天气很好我们去公园吧"),
            ("今天天气很好", "，我们去公园吧", "今天天气很好，我们去公园吧"),
            ("今天天气很好。", "我们去公园吧", "今天天气很好。我们去公园吧"),
            ("他说「你好", "」然后走了", "他说「你好」然后走了"),
            ("他说「你好。」", "然后走了", "他说「你好。」然后走了"),
            ("（你好）", "世界", "（你好）世界"),
        ]
        for (base, addition, expected) in fixtures {
            XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: base, addition: addition), expected)
        }
        for opener in ["「", "『", "（", "【", "《", "〈"] {
            XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "他说", addition: "\(opener)你好"),
                "他说\(opener)你好", "Opening bracket: \(opener)")
            XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "他说\(opener)", addition: "你好"),
                "他说\(opener)你好", "Truncated opening bracket: \(opener)")
        }
    }

    func testRepeatedSpeechAcrossDisjointChunksIsNeverDeleted() {
        let fixtures = [
            ("我真的不知道", "不知道该怎么办", "我真的不知道不知道该怎么办"),
            ("我真的不知道", "不知道", "我真的不知道不知道"),
            ("不知道", "不知道该怎么办", "不知道不知道该怎么办"),
            ("the quick brown fox jumps", "fox jumps over the dog", "the quick brown fox jumps fox jumps over the dog"),
        ]
        for (base, addition, expected) in fixtures {
            XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: base, addition: addition), expected)
        }
    }

    func testEmptyChunkDoesNotAddASeparator() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "", addition: "你好"), "你好")
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "你好", addition: ""), "你好")
    }
}

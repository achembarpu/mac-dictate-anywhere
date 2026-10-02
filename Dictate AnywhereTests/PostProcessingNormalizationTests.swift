import XCTest
@testable import Dictate_Anywhere

final class PostProcessingNormalizationTests: XCTestCase {
    func testLiteralApologyIsPreservedButNewRefusalIsRejected() {
        let input = "i am sorry Maya but we cannot ship version 2.4 today"
        XCTAssertFalse(looksLikeNewRefusalMessage(input: input, output: "I am sorry, Maya, but we cannot ship version 2.4 today."))
        XCTAssertTrue(looksLikeNewRefusalMessage(input: input, output: "I am sorry, but I cannot assist with that request."))
    }

    func testEnvelopeIsRemovedOnlyWhenModelAddedIt() {
        XCTAssertEqual(stripCleanupTranscriptEnvelope("<transcript>What time?</transcript>", original: "what time"), "What time?")
        let literal = "<transcript>Some code</transcript>"
        XCTAssertEqual(stripCleanupTranscriptEnvelope(literal, original: literal), literal)
    }
    func testMalformedOrUnknownStructuredOutputPreservesOriginal() {
        let original = "send the full report and its appendix"
        for response in [
            #"{"action":"pasteCleanedText","text":"Send the full report"#,
            #"{"action":"unknown","text":"Partial"}"#,
            "<think>Some reasoning without a final answer",
            #"{"text":"Partial"}"#
        ] {
            XCTAssertEqual(cleanedRemotePostProcessingResponse(from: response, originalText: original), original)
        }
    }

    func testRemoteCleanupExtractsStructuredResultBeforeTrailingReasoningToken() {
        let original = "i want to test something can you give me fit and fill buttons so two buttons right next to the sample image one is fit and the other is fill i want to test if it does the job and then we will talk and see if we can take this to production"
        let expected = "I want to test something. Can you give me fit and fill buttons? So, two buttons right next to the sample image. One of them is fit, and the other one is fill. I just want to test and see if it actually does the job, and then we'll talk. Then we will see if we can take this to production."
        let response = #"""
        {
          "action": "pasteCleanedText",
          "text": "I want to test something. Can you give me fit and fill buttons? So, two buttons right next to the sample image. One of them is fit, and the other one is fill. I just want to test and see if it actually does the job, and then we'll talk. Then we will see if we can take this to production."
        }
        </think>.
        """#

        XCTAssertEqual(
            cleanedRemotePostProcessingResponse(from: response, originalText: original),
            expected
        )
    }

    func testRemoteCleanupHandlesThinkingTextAndJSONSyntaxInsideCleanedText() {
        let response = #"""
        <think>I considered an earlier {draft}.</think>
        {
          "action": "pasteCleanedText",
          "text": "Use the \"Fit {content}\" option."
        }
        trailing commentary
        """#

        XCTAssertEqual(
            cleanedRemotePostProcessingResponse(
                from: response,
                originalText: "use the fit content option"
            ),
            "Use the \"Fit {content}\" option."
        )
    }

    func testRemoteCleanupHonorsPasteAsIsInsideReasoningEnvelope() {
        let original = "Leave {this} exactly as dictated."
        let response = #"""
        reasoning
        {"action":"pasteTranscriptAsIs","text":null}
        </think>
        """#

        XCTAssertEqual(
            cleanedRemotePostProcessingResponse(from: response, originalText: original),
            original
        )
    }

    func testRemoteCleanupStillAcceptsPlainTextFallback() {
        XCTAssertEqual(
            cleanedRemotePostProcessingResponse(
                from: "Cleaned plain-text transcript.",
                originalText: "cleaned plain text transcript"
            ),
            "Cleaned plain-text transcript."
        )
    }

    func testEmDashBetweenHanBecomesFullwidthComma() {
        XCTAssertEqual(normalizePostProcessedTranscript("我\u{2014}觉得可以"), "我\u{FF0C}觉得可以")
        XCTAssertEqual(normalizePostProcessedTranscript("我\u{2014}\u{2014}觉得可以"), "我\u{FF0C}觉得可以")
    }

    func testEmDashInLatinStillBecomesCommaSpace() {
        XCTAssertEqual(normalizePostProcessedTranscript("well\u{2014}maybe"), "well, maybe")
    }

    func testFullwidthSpacingCleanup() {
        XCTAssertEqual(normalizePostProcessedTranscript("你好 \u{FF0C}世界"), "你好\u{FF0C}世界")
        XCTAssertEqual(normalizePostProcessedTranscript("好的 \u{3002}"), "好的\u{3002}")
    }

    func testExistingLatinCleanupUnchanged() {
        XCTAssertEqual(normalizePostProcessedTranscript("done ."), "done .") // " ." is NOT rewritten today — do not add new ASCII rules
        XCTAssertEqual(normalizePostProcessedTranscript("a , b"), "a, b")
    }
}

import XCTest
@testable import Dictate_Anywhere

final class TextInserterTests: XCTestCase {
    func testNormalizedForInsertionNeverInventsPunctuation() {
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好"), "你好")
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好。"), "你好。")
        XCTAssertEqual(TextInserter.normalizedForInsertion("hello"), "hello")
        XCTAssertEqual(TextInserter.normalizedForInsertion("hello?"), "hello?")
        XCTAssertEqual(TextInserter.normalizedForInsertion("  你好  "), "你好")
        XCTAssertEqual(TextInserter.normalizedForInsertion(""), "")
    }

    func testPasteScriptPrecompilesWithoutExecuting() async {
        let inserter = TextInserter()
        let ready = await inserter.prewarmPasteScript()
        XCTAssertTrue(ready)
    }
}

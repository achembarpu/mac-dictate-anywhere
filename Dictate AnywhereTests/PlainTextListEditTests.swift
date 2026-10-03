import XCTest
@testable import Dictate_Anywhere

@MainActor
final class PlainTextListEditTests: XCTestCase {
    func testPlainNumberedInsertionDoesNotDuplicateFollowingNumbers() throws {
        let before = "1. Apples\n2. "
        let after = "\n3. Oranges"
        let context = makeContext(before: before, after: after)
        let plan = try XCTUnwrap(ModelInsertionPlan.decode(#"{"items":["Tangerines","Blueberries"],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        let insertion = TextInserter().preparedTextForInsertion(plan.text,
            targetBundleIdentifier: nil, targetProcessIdentifier: 123, context: context,
            style: .original, knownTerms: [], modelInsertionPlan: plan, preserveModelFormatting: true)
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: insertion, context: context))
        XCTAssertEqual(edit.expectedValue, "1. Apples\n2. Tangerines\n3. Blueberries\n4. Oranges")
        XCTAssertEqual(edit.caretLocation, (before + insertion).utf16.count)
    }

    func testNumberingPreservesNestedTextAndStopsAtIndependentSection() throws {
        let before = "Shopping 🛒\n8) Apples\n9) "
        let after = "\n10) Oranges\n    1. Nested\n    continuation\n\n11) Flowers\nParagraph\n12) Unrelated"
        let insertion = "Tangerines\n10) Blueberries"
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: insertion,
            context: makeContext(before: before, after: after)))
        XCTAssertEqual(edit.expectedValue, before + insertion + "\n11) Oranges\n    1. Nested\n    continuation\n\n12) Flowers\nParagraph\n12) Unrelated")
    }

    func testNumberingPreservesCRLFAndIndentedList() throws {
        let before = "  1. Apples\r\n  2. "
        let after = "\r\n  3. Oranges\r\n1. Outer list"
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: "Pears\n  3. Grapes",
            context: makeContext(before: before, after: after)))
        XCTAssertEqual(edit.expectedValue, before + "Pears\n  3. Grapes\r\n  4. Oranges\r\n1. Outer list")
    }

    func testNumberingRejectsStaleContextSelectionsAndRichLists() {
        let before = "1. Apples\n2. "
        let after = "\n3. Oranges"
        var context = makeContext(before: before, after: after)
        let range = NSRange(location: before.utf16.count, length: 0)
        XCTAssertNil(PlainTextListEdit.prepare(value: before + "changed" + after,
            selection: range, insertion: "Pears\n3. Grapes", context: context))
        XCTAssertNil(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: range.location, length: 1), insertion: "Pears\n3. Grapes", context: context))
        context.capturedListItemInsertion = .emptyStructuralItem(itemText: "", previousItemText: "Apples", nextItemText: "Oranges")
        XCTAssertNil(PlainTextListEdit.prepare(value: before + after, selection: range,
            insertion: "Pears\nGrapes", context: context))
    }

    private func makeContext(before: String, after: String, purpose: DictationFieldPurpose = .unknown) -> DictationContext {
        DictationContext(processIdentifier: 123, bundleIdentifier: "com.example.editor", appName: "Fixture",
            category: .other, documentURL: nil, documentTitle: nil, fieldRole: "AXTextArea", fieldSubrole: nil,
            fieldPurpose: purpose, textBeforeCursor: before, selectedText: "", textAfterCursor: after,
            isSecureField: false, isContextExcluded: false)
    }
}

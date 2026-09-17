import XCTest
@testable import Dictate_Anywhere

final class DictationFocusResolverTests: XCTestCase {
    private final class Node {
        var pid: pid_t = 42
        var role = "AXGroup"
        var focused = false
        var children: [Node] = []

        init(role: String = "AXGroup", focused: Bool = false, children: [Node] = []) {
            self.role = role
            self.focused = focused
            self.children = children
        }
    }

    private func resolve(
        direct: Node? = nil, system: Node? = nil, window: Node? = nil,
        now: () -> TimeInterval = { 0 }
    ) -> Node? {
        DictationFocusResolver.resolve(
            targetPID: 42,
            applicationFocus: { direct }, systemFocus: { system }, focusedWindow: { window },
            processIdentifier: { $0.pid }, role: { $0.role }, isFocused: { $0.focused },
            children: { $0.children }, now: now
        )
    }

    func testApplicationFocusIsPreferred() {
        let direct = Node(role: "AXTextArea")
        XCTAssertTrue(resolve(direct: direct, system: Node(role: "AXTextField", focused: true)) === direct)
    }

    func testMissingApplicationFocusUsesSystemFocusFromSameProcess() {
        let field = Node(role: "AXTextArea", focused: true)
        XCTAssertTrue(resolve(system: field) === field)
    }

    func testStaleSystemFocusFromAnotherAppIsRejected() {
        let field = Node(role: "AXTextArea", focused: true)
        field.pid = 99
        XCTAssertNil(resolve(system: field))
        XCTAssertNil(resolve(direct: field))
    }

    func testSystemControlMustStillReportFocus() {
        XCTAssertNil(resolve(system: Node(role: "AXTextArea")))
    }

    func testMissingApplicationAndSystemFocusFindsNestedFocusedEditor() {
        let editor = Node(role: "AXTextArea", focused: true)
        let window = Node(children: [Node(children: [Node(role: "AXWebArea", children: [editor])])])
        XCTAssertTrue(resolve(window: window) === editor)
    }

    func testWebAreaPlaceholderDoesNotHideFocusedEditor() {
        let editor = Node(role: "AXTextArea", focused: true)
        let webArea = Node(role: "AXWebArea", children: [editor])
        XCTAssertTrue(resolve(direct: webArea, window: Node(children: [webArea])) === editor)
        XCTAssertFalse(DictationFocusResolver.isTextInput(role: "AXWebArea"))
    }

    func testNeverGuessesAmongUnfocusedTextFields() {
        XCTAssertNil(resolve(window: Node(children: [Node(role: "AXTextArea"), Node(role: "AXTextField")])))
    }

    func testDoesNotTraverseForeignProcessOrEditableControlChildren() {
        let editor = Node(role: "AXTextArea", focused: true)
        let foreign = Node(children: [editor])
        foreign.pid = 99
        let password = Node(role: "AXTextField", children: [editor])
        XCTAssertNil(resolve(window: Node(children: [foreign, password])))
    }

    func testTraversalStopsAtNodeAndDepthBudgetsEvenWithCycles() {
        let cycle = Node()
        cycle.children = [cycle]
        XCTAssertNil(resolve(window: cycle))
        let editor = Node(role: "AXTextArea", focused: true)
        let children = (0..<128).map { _ in Node() } + [editor]
        XCTAssertNil(resolve(window: Node(children: children)))
    }

    func testTraversalStopsAtTimeBudget() {
        var time: TimeInterval = 0
        let editor = Node(role: "AXTextArea", focused: true)
        XCTAssertNil(resolve(window: Node(children: [editor]), now: {
            defer { time += 0.3 }
            return time
        }))
    }
}

import XCTest
import SwiftUI
@testable import Dictate_Anywhere

@MainActor
final class ShortcutLayoutTests: XCTestCase {
    func testShortcutRecorderControlsStayOnOneLineWhenWidthIsConstrained() {
        let view = ShortcutRecorderView(
            accessibilityName: "Shortcut 1",
            displayName: "L\u{2303}L\u{2325}L\u{2318}",
            onRecord: { _, _, _ in },
            onClear: {}
        )
        .frame(width: 260, alignment: .trailing)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            return XCTFail("shortcut recorder failed to render")
        }

        XCTAssertLessThanOrEqual(image.size.height, 40, "keycaps and action buttons must remain single-line")
    }
}

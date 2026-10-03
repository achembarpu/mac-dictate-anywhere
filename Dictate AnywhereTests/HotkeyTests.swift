import XCTest
@testable import Dictate_Anywhere

final class HotkeyTests: XCTestCase {

    // MARK: - Display name formatting

    func testDisplayNameSideAwareModifiers() {
        let leftCommand = Settings.displayName(keyCode: nil, modifiers: [.command, .leftCommand])
        XCTAssertEqual(leftCommand, "L\u{2318}")

        let rightCommand = Settings.displayName(keyCode: nil, modifiers: [.command, .rightCommand])
        XCTAssertEqual(rightCommand, "R\u{2318}")
    }

    // MARK: - Modifier normalization

    func testNormalizedModifiersInsertsGenericForSided() {
        let normalized = Settings.normalizedHotkeyModifiers([.leftCommand])
        XCTAssertTrue(normalized.contains(.command))
        XCTAssertTrue(normalized.contains(.leftCommand))
    }

    func testHotkeyModifiersFromCGFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let modifiers = Settings.hotkeyModifiers(from: flags)
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertFalse(modifiers.contains(.control))
    }

    // MARK: - Keycap tokenizer

    func testShortcutKeycapsPreserveSidesFunctionAndNamedKeys() {
        for (display, expected) in [
            ("", [String]()),
            ("⌃⌥⌘", ["⌃", "⌥", "⌘"]),
            ("L⌃L⌥L⌘", ["L ⌃", "L ⌥", "L ⌘"]),
            ("fn", ["fn"]), ("fn⌘", ["fn", "⌘"]),
            ("⌘A", ["⌘", "A"]), ("R⌘Space", ["R ⌘", "Space"]),
            ("F5", ["F5"]), ("⌘⎋", ["⌘", "Esc"])
        ] {
            XCTAssertEqual(HotkeyKeycapTokenizer.tokens(from: display), expected, display)
        }
        XCTAssertEqual(Settings.displayName(keyCode: 53, modifiers: []), "Esc")
    }

    // MARK: - Conflict detection

    func testInternalConflictDetectsDuplicates() {
        let modifiers = HotkeyModifiers([.control, .option, .command]).rawValue
        let a = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: modifiers, displayName: "x", mode: .holdToRecord)
        let b = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: modifiers, displayName: "x", mode: .handsFreeToggle)
        XCTAssertNotNil(ConflictDetector.internalConflict(for: a, in: [a, b]))
    }

    func testInternalConflictNilWhenUnique() {
        let a = HotkeyBinding(
            id: UUID(), keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.control, .option]).rawValue,
            displayName: "a", mode: .holdToRecord
        )
        let b = HotkeyBinding(
            id: UUID(), keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.command, .shift]).rawValue,
            displayName: "b", mode: .holdToRecord
        )
        XCTAssertNil(ConflictDetector.internalConflict(for: a, in: [a, b]))
    }

    func testInternalConflictNilForUnboundBinding() {
        let unbound = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: 0, displayName: "", mode: .holdToRecord)
        XCTAssertNil(ConflictDetector.internalConflict(for: unbound, in: [unbound]))
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class SettingsInteractionTests: XCTestCase {
    private func providerTaskID() -> String {
        AIPostProcessingView.providerTaskID(
            settings: Settings.shared, ollamaModelActionsRevision: 0
        )
    }

    func testReplacingStoredOpenRouterKeyRefreshesAvailabilityWithoutExposingKey() {
        let settings = Settings.shared
        let savedKey = settings.openRouterAPIKey
        defer { settings.openRouterAPIKey = savedKey }
        settings.openRouterAPIKey = "audit-test-openrouter-key-one"
        let firstID = providerTaskID()
        settings.openRouterAPIKey = "audit-test-openrouter-key-two"
        let secondID = providerTaskID()
        XCTAssertNotEqual(firstID, secondID, "Replacing an existing key must invalidate the provider check.")
        XCTAssertFalse(firstID.contains("audit-test-openrouter-key-one"))
        XCTAssertFalse(secondID.contains("audit-test-openrouter-key-two"))
    }

    func testReplacingStoredOpenAICompatibleKeyRefreshesAvailabilityWithoutExposingKey() {
        let settings = Settings.shared
        let savedKey = settings.openAICompatibleAPIKey
        defer { settings.openAICompatibleAPIKey = savedKey }
        settings.openAICompatibleAPIKey = "audit-test-compatible-key-one"
        let firstID = providerTaskID()
        settings.openAICompatibleAPIKey = "audit-test-compatible-key-two"
        let secondID = providerTaskID()
        XCTAssertNotEqual(firstID, secondID, "Replacing an existing key must invalidate the provider check.")
        XCTAssertFalse(firstID.contains("audit-test-compatible-key-one"))
        XCTAssertFalse(secondID.contains("audit-test-compatible-key-two"))
    }

    func testReplacingInlineOpenRouterKeyRefreshesAvailabilityWithoutExposingKey() {
        let settings = Settings.shared
        let savedVariable = settings.openRouterAPIKeyEnvironmentVariable
        defer { settings.openRouterAPIKeyEnvironmentVariable = savedVariable }
        settings.openRouterAPIKeyEnvironmentVariable = "sk-or-audit-test-one"
        let firstID = providerTaskID()
        settings.openRouterAPIKeyEnvironmentVariable = "sk-or-audit-test-two"
        let secondID = providerTaskID()
        XCTAssertNotEqual(firstID, secondID, "Changing an inline credential must invalidate the provider check.")
        XCTAssertFalse(firstID.contains("sk-or-audit-test-one"))
        XCTAssertFalse(secondID.contains("sk-or-audit-test-two"))
    }

    func testMultilineEditorDisplaysTheAcceptedBindingValueAfterBoundedInput() async throws {
        var acceptedText = ""
        let view = SettingsMultilineTextArea(
            text: Binding(get: { acceptedText }, set: { acceptedText = String($0.prefix(4)) }),
            label: "Bounded instructions", placeholder: "Enter instructions"
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(findTextView(in: host))
        editor.insertText("abcdef", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(acceptedText, "abcd")
        XCTAssertEqual(editor.string, acceptedText, "The editor must not show text discarded by the settings binding.")
        editor.breakUndoCoalescing()
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(acceptedText, "")
        XCTAssertEqual(editor.string, "")
        editor.undoManager?.redo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(acceptedText, "abcd")
        XCTAssertEqual(editor.string, "abcd")
        editor.insertText("ef", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(acceptedText, "abcd")
        XCTAssertEqual(editor.string, "abcd", "Rejected input must be removed even when the bound value is unchanged.")
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let found = findTextView(in: child) { return found }
        }
        return nil
    }
}

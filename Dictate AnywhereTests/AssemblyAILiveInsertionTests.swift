import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Explicitly opt in with TEST_RUNNER_DICTATE_ASSEMBLYAI_LIVE_TESTS=1 when
/// invoking xcodebuild. Uses the Dev app's configured provider and credentials;
/// sends only generated grocery audio and the fixture text below.
final class AssemblyAILiveInsertionTests: XCTestCase {
    @MainActor
    func testLiveSentenceAndListInsertions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATE_ASSEMBLYAI_LIVE_TESTS"] == "1")
        let settings = Settings.shared
        try XCTSkipUnless(settings.assemblyAIOutputMode == .polished
            && settings.dictationContextAwarenessEnabled
            && settings.shareDictationContextWithRemoteProviders,
            "Requires Polished mode with context sharing enabled in the Dev app.")
        let engine = AssemblyAIEngine()
        try XCTSkipUnless(engine.isReady, "Configure an AssemblyAI key in the Dev app.")
        let testCapture = ProcessInfo.processInfo.environment["DICTATE_LIVE_CAPTURE_TESTS"] == "1"
        if testCapture {
            XCTAssertTrue(AXIsProcessTrusted(), "The signed test host needs existing Accessibility permission; this test never requests it.")
            guard AXIsProcessTrusted() else { return }
        }

        let fixtures = [
            (spoken: "tangerines", before: "I need to buy some groceries: apples, bananas,",
             after: " oranges, and some sourdough starter.",
             expected: "I need to buy some groceries: apples, bananas, tangerines, oranges, and some sourdough starter."),
            (spoken: "strawberries", before: "I need to buy:\n- Apples\n- Bananas\n- ",
             after: "\n- Oranges\n- Flowers",
             expected: "I need to buy:\n- Apples\n- Bananas\n- Strawberries\n- Oranges\n- Flowers"),
            (spoken: "strawberries", before: "I need to buy:\nApples\nBananas\n",
             after: "\nOranges\nFlowers",
             expected: "I need to buy:\nApples\nBananas\nStrawberries\nOranges\nFlowers"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, fixture) in fixtures.enumerated() {
            let audio = directory.appendingPathComponent("fixture-\(index).wav")
            let synthesis = Process()
            synthesis.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            synthesis.arguments = ["-o", audio.path, "--file-format=WAVE", "--data-format=LEI16@16000", fixture.spoken]
            try synthesis.run()
            synthesis.waitUntilExit()
            guard synthesis.terminationStatus == 0 else {
                XCTFail("Could not synthesize fixture audio")
                return
            }
            var context = DictationContext(
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: "com.example.insertion-fixture", appName: "Insertion Test",
                category: .other, documentURL: nil, documentTitle: nil,
                fieldRole: "AXTextArea", fieldSubrole: nil, fieldPurpose: .unknown,
                textBeforeCursor: fixture.before, selectedText: "", textAfterCursor: fixture.after,
                isSecureField: false, isContextExcluded: false
            )
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
            editor.string = fixture.before + fixture.after
            editor.setSelectedRange(NSRange(location: fixture.before.utf16.count, length: 0))
            let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Dictation insertion test fixture"
            window.contentView = editor
            defer { window.close() }
            if testCapture {
                let pid = ProcessInfo.processInfo.processIdentifier
                // App activation and AX focus are asynchronous, especially on
                // the first fixture while the test host is still launching.
                for _ in 0..<20 {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(editor)
                    try await Task.sleep(for: .milliseconds(100))
                    context = await Task.detached {
                        DictationContextCapture.capture(processIdentifier: pid,
                            bundleIdentifier: "com.example.insertion-fixture", appName: "Insertion Test", rules: [])
                    }.value
                    if context.textBeforeCursor == fixture.before && context.textAfterCursor == fixture.after { break }
                }
                XCTAssertEqual(context.textBeforeCursor, fixture.before)
                XCTAssertEqual(context.textAfterCursor, fixture.after)
                guard context.hasTextPositionSnapshot else { return }
            }
            engine.setSessionDictationContext(context)
            let text = try await engine.transcribeRecording(at: audio)
            XCTAssertNotNil(engine.lastInsertionPlan, "Provider must return an insertion plan for fixture \(index)")
            let insertion = TextInserter().preparedTextForInsertion(
                text, targetBundleIdentifier: context.bundleIdentifier,
                targetProcessIdentifier: context.processIdentifier, context: context,
                style: settings.dictationWritingStyle(for: .other), knownTerms: [],
                modelInsertionPlan: engine.lastInsertionPlan,
                preserveModelFormatting: engine.lastResultWasPolished
            )
            editor.insertText(insertion, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, fixture.expected, "Live provider fixture \(index)")
            print("Live insertion fixture \(index) (capture=\(testCapture)): \(editor.string.debugDescription)")
        }
    }
}

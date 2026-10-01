import AppKit
import XCTest
@testable import Dictate_Anywhere

final class AttentionIssueTests: XCTestCase {
    func testPermissionWarningsWaitForInitialAsyncCheck() {
        let issues = AttentionIssue.pending(
            permissionsChecked: false,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .parakeet,
            speechSetupNeeded: false,
            automationDenied: true
        )

        XCTAssertTrue(issues.isEmpty)
    }

    func testOnlyUnresolvedIssuesAppearInPriorityOrder() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .parakeet,
            speechSetupNeeded: true,
            automationDenied: true
        )

        XCTAssertEqual(issues.map(\.id), [.microphone, .accessibility, .speechSetup, .automation])
        XCTAssertEqual(issues.first?.actionTitle, "Open Settings")
        XCTAssertTrue(issues.last?.isOptional == true)
    }

    func testFirstMicrophoneRequestUsesConsentButtonTitle() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: true,
            accessibilityGranted: true,
            engineChoice: .appleSpeech,
            speechSetupNeeded: false,
            automationDenied: false
        )

        XCTAssertEqual(issues.first?.actionTitle, "Allow Microphone")
    }

    func testReadySetupDoesNotShowIssue() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .appleSpeech,
            speechSetupNeeded: false,
            automationDenied: false
        )

        XCTAssertTrue(issues.isEmpty)
    }

    func testOptionalAutomationIssueAppearsOnlyAfterConfirmedDenial() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .assemblyAI,
            speechSetupNeeded: false,
            automationDenied: true
        )

        XCTAssertEqual(issues.map(\.id), [.automation])
        XCTAssertEqual(PasteScriptOutcome.fromAppleScriptError(nil), .success)
        XCTAssertEqual(
            PasteScriptOutcome.fromAppleScriptError([NSAppleScript.errorNumber: -1743]),
            .automationDenied
        )
        XCTAssertEqual(
            PasteScriptOutcome.fromAppleScriptError([NSAppleScript.errorNumber: -1728]),
            .failed
        )
    }
}

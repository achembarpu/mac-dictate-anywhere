import XCTest
@testable import Dictate_Anywhere

final class PermissionsTests: XCTestCase {
    @MainActor
    func testRefreshUpdatesMicrophonePermissionAfterReturningFromSettings() async {
        let status = MutablePermissionStatus(microphoneGranted: false)
        let permissions = Permissions(statusProvider: {
            (mic: status.microphoneGranted, accessibility: false)
        })

        await permissions.refresh()
        XCTAssertFalse(permissions.micGranted)

        // Simulate enabling Microphone in System Settings before returning to
        // the app, which triggers its active-state permission refresh.
        status.microphoneGranted = true
        await permissions.refresh()

        XCTAssertTrue(permissions.micGranted)
    }

    @MainActor
    func testStartupAndUseChecksSharePermissionStateWithoutPrompting() async {
        let status = MutablePermissionStatus(microphoneGranted: true)
        status.accessibilityGranted = true
        status.automationAuthorization = .granted
        let permissions = Permissions(
            statusProvider: { status.coreStatus },
            automationStatusProvider: { status.automationAuthorization }
        )

        await permissions.refresh()
        XCTAssertTrue(permissions.micGranted)
        XCTAssertTrue(permissions.accessibilityGranted)
        XCTAssertFalse(permissions.automationDenied)

        status.microphoneGranted = false
        status.accessibilityGranted = false
        status.automationAuthorization = .denied
        await permissions.refreshForDictation()
        XCTAssertFalse(permissions.micGranted)
        XCTAssertFalse(permissions.accessibilityGranted)
        XCTAssertFalse(permissions.automationDenied, "The hot path does not preflight Automation")

        await permissions.refresh()
        XCTAssertTrue(permissions.automationDenied)

        // An inconclusive preflight does not erase a confirmed paste denial.
        status.automationAuthorization = .unknown
        permissions.recordAutomationPastePermission(denied: true)
        await permissions.refresh()
        XCTAssertTrue(permissions.automationDenied)
        permissions.recordAutomationPastePermission(denied: false)
        XCTAssertFalse(permissions.automationDenied)
    }
}

private final class MutablePermissionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneValue: Bool
    private var accessibilityValue = false
    private var automationValue: Permissions.AutomationAuthorization = .unknown

    init(microphoneGranted: Bool) {
        microphoneValue = microphoneGranted
    }

    var microphoneGranted: Bool {
        get { lock.withLock { microphoneValue } }
        set { lock.withLock { microphoneValue = newValue } }
    }

    var accessibilityGranted: Bool {
        get { lock.withLock { accessibilityValue } }
        set { lock.withLock { accessibilityValue = newValue } }
    }

    var automationAuthorization: Permissions.AutomationAuthorization {
        get { lock.withLock { automationValue } }
        set { lock.withLock { automationValue = newValue } }
    }

    var coreStatus: (mic: Bool, accessibility: Bool) {
        lock.withLock { (microphoneValue, accessibilityValue) }
    }
}

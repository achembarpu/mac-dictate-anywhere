import Foundation

/// Actionable setup problems shown in the single main-window banner.
/// The order is deliberate: dictation blockers precede optional improvements.
struct AttentionIssue: Identifiable, Equatable {
    enum ID: String, Hashable {
        case microphone
        case accessibility
        case speechSetup
        case automation
    }

    let id: ID
    let title: String
    let message: String
    let actionTitle: String
    let isOptional: Bool

    static func pending(
        permissionsChecked: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        engineChoice: TranscriptionEngineChoice,
        speechSetupNeeded: Bool,
        automationDenied: Bool
    ) -> [AttentionIssue] {
        var issues: [AttentionIssue] = []

        if permissionsChecked && !microphoneGranted {
            issues.append(AttentionIssue(
                id: .microphone,
                title: "Microphone access needed",
                message: "Dictation cannot start until microphone access is enabled.",
                actionTitle: "Enable Microphone",
                isOptional: false
            ))
        }

        if permissionsChecked && !accessibilityGranted {
            issues.append(AttentionIssue(
                id: .accessibility,
                title: "Accessibility access needed",
                message: "Enable Dictate Anywhere in System Settings for shortcuts and pasting.",
                actionTitle: "Open Settings",
                isOptional: false
            ))
        }

        if speechSetupNeeded {
            let message: String
            switch engineChoice {
            case .appleSpeech:
                message = "Finish setting up Apple Speech before dictating."
            case .assemblyAI:
                message = "Add an AssemblyAI API key before dictating."
            case .parakeet:
                message = "Download a speech model before dictating."
            }
            issues.append(AttentionIssue(
                id: .speechSetup,
                title: "Dictation setup needed",
                message: message,
                actionTitle: "Set Up",
                isOptional: false
            ))
        }

        if permissionsChecked && automationDenied {
            issues.append(AttentionIssue(
                id: .automation,
                title: "System Events access is off",
                message: "Pasting still works through the keyboard fallback. Enable Automation to use the AppleScript path.",
                actionTitle: "Open Settings",
                isOptional: true
            ))
        }

        return issues
    }
}

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
        microphoneCanPrompt: Bool,
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
                message: "Allow microphone access to start dictating.",
                actionTitle: microphoneCanPrompt ? "Allow Microphone" : "Open Settings",
                isOptional: false
            ))
        }

        if permissionsChecked && !accessibilityGranted {
            issues.append(AttentionIssue(
                id: .accessibility,
                title: "Accessibility access needed",
                message: "Allow Accessibility for shortcuts and pasting.",
                actionTitle: "Open Settings",
                isOptional: false
            ))
        }

        if speechSetupNeeded {
            let message: String
            switch engineChoice {
            case .appleSpeech:
                message = "Set up Apple Speech to start dictating."
            case .assemblyAI:
                message = "Add an AssemblyAI API key to start dictating."
            case .parakeet:
                message = "Download a speech model to start dictating."
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
                message: "Allow System Events for AppleScript paste. Keyboard paste still works.",
                actionTitle: "Open Settings",
                isOptional: true
            ))
        }

        return issues
    }
}

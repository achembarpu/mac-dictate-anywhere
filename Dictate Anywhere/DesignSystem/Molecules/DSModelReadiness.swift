import SwiftUI

struct DSModelReadinessStatus: View {
    let readiness: ModelReadiness

    var body: some View {
        if readiness.isWorking {
            DSLoadingMessage(text: readiness.title)
        } else {
            DSStatusPill(text: readiness.title,
                dotColor: readiness.isReady ? DS.Colors.success : DS.Colors.textSecondary,
                textColor: readiness.isReady ? DS.Colors.successText : DS.Colors.textSecondary,
                fill: readiness.isReady ? DS.Colors.successSoft : DS.Colors.bgInset)
        }
    }
}

/// The same status, progress, detail and action layout for every model path.
struct DSModelReadinessRow: View {
    let readiness: ModelReadiness
    var label = "Status"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            DSInfoRow(label: label) {
                HStack(spacing: 10) {
                    DSModelReadinessStatus(readiness: readiness)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(.dsSecondary)
                            .disabled(readiness.isWorking)
                    }
                }
            }
            if let progress = readiness.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("\(label) download")
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
            if let detail = readiness.detail {
                DSFieldMessage(text: detail, tone: .error)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
        }
    }
}

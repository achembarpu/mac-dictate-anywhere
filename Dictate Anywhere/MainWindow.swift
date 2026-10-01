//
//  MainWindow.swift
//  Dictate Anywhere
//
//  Root layout: custom design-system sidebar + detail page.
//

import SwiftUI

enum SidebarPage: String, CaseIterable, Identifiable {
    case models
    case settings
    case shortcuts
    case textOverlay
    case aiPostProcessing
    case internalPrompts
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Speech Model"
        case .settings: return "General"
        case .shortcuts: return "Shortcuts"
        case .textOverlay: return "Text & Overlay"
        case .aiPostProcessing: return "Transcript Cleanup"
        case .internalPrompts: return "Internal Prompts"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .models: return "cpu"
        case .settings: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .textOverlay: return "textformat"
        case .aiPostProcessing: return "wand.and.stars"
        case .internalPrompts: return "text.bubble"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    func isVisible(for engine: TranscriptionEngineChoice) -> Bool {
        switch self {
        case .aiPostProcessing:
            return engine != .assemblyAI
        case .internalPrompts:
            return engine.supportsInternalPromptCustomization
        default:
            return true
        }
    }
}

struct AttentionBanner: View {
    let issues: [AttentionIssue]
    @Binding var selectedID: AttentionIssue.ID?
    let action: (AttentionIssue.ID) -> Void

    private var selectedIndex: Int {
        issues.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    var body: some View {
        if !issues.isEmpty {
            let issue = issues[selectedIndex]
            HStack(spacing: 12) {
                Image(systemName: issue.isOptional ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.accentDeep)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(DS.Fonts.ui(12.5, .semibold))
                    Text(issue.message)
                        .font(DS.Fonts.ui(12))
                }
                .foregroundStyle(DS.Colors.panelText)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(issue.actionTitle) { action(issue.id) }
                    .buttonStyle(.dsSecondary)

                if issues.count > 1 {
                    HStack(spacing: 4) {
                        DSIconButton(
                            systemImage: "chevron.left",
                            accessibilityLabel: "Previous setup issue"
                        ) { selectIssue(offset: -1) }
                        Text("\(selectedIndex + 1) of \(issues.count)")
                            .font(DS.Fonts.ui(11))
                            .monospacedDigit()
                            .accessibilityLabel("Issue \(selectedIndex + 1) of \(issues.count)")
                        DSIconButton(
                            systemImage: "chevron.right",
                            accessibilityLabel: "Next setup issue"
                        ) { selectIssue(offset: 1) }
                    }
                    .foregroundStyle(DS.Colors.panelText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 50)
            .background(DS.Colors.accentSoft)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DS.Colors.border)
                    .frame(height: 1)
            }
        }
    }

    private func selectIssue(offset: Int) {
        selectedID = issues[(selectedIndex + offset + issues.count) % issues.count].id
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 0) {
            SidebarView(selectedPage: $appState.selectedPage)

            VStack(spacing: 0) {
                AttentionBanner(
                    issues: appState.attentionIssues,
                    selectedID: $appState.selectedAttentionIssueID,
                    action: appState.resolveAttentionIssue
                )

                detailView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.bgWindow)
        .onAppear { selectRecoveryIssueIfNeeded() }
        .onChange(of: appState.recoveryStore.errorMessage) { _, error in
            if error != nil { selectRecoveryIssueIfNeeded() }
        }
        .frame(
            minWidth: MainWindowSizing.minimumWidth,
            maxWidth: .infinity,
            minHeight: MainWindowSizing.minimumHeight,
            maxHeight: .infinity
        )
    }

    private func selectRecoveryIssueIfNeeded() {
        guard appState.recoveryStore.errorMessage != nil else { return }
        appState.selectedAttentionIssueID = appState.permissions.hasChecked
            && !appState.permissions.micGranted ? .microphone : .recovery
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedPage {
        case .models:
            ModelsView()
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsView()
        case .textOverlay:
            TextOverlayView()
        case .aiPostProcessing:
            AIPostProcessingView()
        case .internalPrompts:
            InternalPromptsView()
        case .history:
            TranscriptHistoryView()
        case .about:
            AboutView()
        }
    }
}

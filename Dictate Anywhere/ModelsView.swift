//
//  ModelsView.swift
//  Dictate Anywhere
//
//  "Speech Model" page: download, delete, engine selector.
//

import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var showDeleteConfirm = false
    @State private var showUnsupportedAppleSpeechAlert = false
    @State private var downloadError: String?

    var body: some View {
        @Bindable var settings = appState.settings
        let selectedModel = settings.parakeetModelChoice

        DSPage {
            DSSectionHeader(
                title: "Speech Model",
                subtitle: pageSubtitle(settings: settings)
            )

            DSSection(overline: "Active Engine") {
                DSDetailRow(label: "Engine", caption: settings.engineChoice.detail) {
                    DSDropdown(
                        selection: Binding(
                            get: { settings.engineChoice },
                            set: { newValue in
                                downloadError = nil
                                if newValue == .appleSpeech, !AppleSpeechEngine.isSupported {
                                    showUnsupportedAppleSpeechAlert = true
                                    return
                                }
                                Task { await appState.handleEngineSelectionChange(newValue) }
                            }
                        ),
                        options: appState.availableEngineChoices,
                        title: engineChoiceTitle,
                        isEnabled: appState.status == .idle
                            && !appState.isPreparingEngine
                            && !appState.parakeetEngine.isDownloading
                    )
                }
            }

            if settings.engineChoice == .parakeet {
                DSSection(overline: "FluidAudio") {
                    DSDetailRow(label: "Variant", caption: selectedModel.detail) {
                        DSDropdown(
                            selection: Binding(
                                get: { settings.parakeetModelChoice },
                                set: { newValue in
                                    downloadError = nil
                                    settings.parakeetModelChoice = newValue
                                    Task {
                                        await appState.parakeetEngine.recheckModelOnDisk(for: newValue)
                                        await appState.handleParakeetModelSelectionChange(userInitiated: true)
                                    }
                                }
                            ),
                            options: ParakeetModelChoice.availableCases,
                            title: \.displayName,
                            isEnabled: appState.status == .idle && !appState.parakeetEngine.isDownloading
                        )
                    }
                    DSDivider()
                    DSInfoRow(
                        label: "Type",
                        value: selectedModel.usesTrueStreaming
                            ? "On-device true streaming speech-to-text"
                            : "On-device speech-to-text"
                    )
                    DSDivider()
                    DSInfoRow(label: "Languages", value: selectedModel.languageSummary)
                    DSDivider()
                    DSInfoRow(label: "Size", value: selectedModel.sizeSummary)
                    if let alternateModel = alternateInstalledModel(excluding: selectedModel) {
                        DSDivider()
                        DSInfoRow(label: "Also installed", value: alternateModel.displayName)
                    }
                    if selectedModel.supportsEndOfUtterance {
                        DSDivider()
                        DSInfoRow(label: "Stop hands-free dictation after speech ends") {
                            Toggle("", isOn: $settings.autoStopAfterSpeechEndsEnabled)
                                .labelsHidden()
                                .toggleStyle(.dsSwitch)
                        }
                    }
                    DSDivider()
                    statusRow
                    if appState.parakeetEngine.isModelDownloaded {
                        DSDivider()
                        DSInfoRow(
                            label: "Remove the downloaded model files from this Mac.",
                            labelColor: DS.Colors.textSecondary,
                            labelWeight: .regular
                        ) {
                            Button("Delete Model…") {
                                showDeleteConfirm = true
                            }
                            .buttonStyle(.dsDestructive)
                            .disabled(appState.status != .idle)
                        }
                    }
                    if let error = downloadError {
                        DSDivider()
                        DSInfoRow(
                            label: error,
                            labelColor: DS.Colors.destructive,
                            labelWeight: .regular
                        ) {
                            EmptyView()
                        }
                    }
                }

                DSHint(text: selectedModel.speechModelFooter)
            } else if settings.engineChoice == .appleSpeech {
                DSSection(overline: "Apple Speech") {
                    DSInfoRow(label: "Type", value: "Latest on-device speech-to-text from Apple")
                    DSDivider()
                    DSInfoRow(label: "Language", value: settings.appleSpeechLanguage.displayName)
                    DSDivider()
                    DSInfoRow(label: "Model storage", value: "Downloaded and managed by macOS")
                    DSDivider()
                    appleSpeechStatusRow
                    if let error = appState.enginePreparationError {
                        DSDivider()
                        DSInfoRow(
                            label: error,
                            labelColor: DS.Colors.destructive,
                            labelWeight: .regular
                        ) {
                            EmptyView()
                        }
                    }
                }

                DSHint(
                    text:
                        "Apple Speech is available on supported Macs running macOS 26 or later. Audio and transcription stay on this Mac."
                )
            } else if settings.engineChoice == .assemblyAI {
                assemblyAIContent(settings: settings)
            }
        }
        .alert("Delete \(selectedModel.displayName)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                    await MainActor.run { applyParakeetSelection(userInitiated: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the \(selectedModel.displayName.lowercased()) speech model (\(selectedModel.sizeSummary)). You can download it again later.")
        }
        .alert(unsupportedAppleSpeechAlertTitle, isPresented: $showUnsupportedAppleSpeechAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unsupportedAppleSpeechAlertMessage)
        }
    }

    private func engineChoiceTitle(_ choice: TranscriptionEngineChoice) -> String {
        if choice == .appleSpeech, !AppleSpeechEngine.isOperatingSystemSupported {
            return "Apple Speech (Requires macOS 26)"
        }
        return choice.displayName
    }

    private func pageSubtitle(settings: Settings) -> String {
        settings.engineChoice == .assemblyAI
            ? "AssemblyAI processes audio in the cloud and returns text ready to paste."
            : "Everything runs on your Mac — your voice never leaves this device."
    }

    @ViewBuilder
    private func assemblyAIContent(settings: Settings) -> some View {
        @Bindable var settings = settings

        DSSection(overline: "AssemblyAI") {
            DSDetailRow(
                label: "API key",
                caption:
                    "Stored in macOS Keychain. You can also launch the app with ASSEMBLYAI_API_KEY set."
            ) {
                HStack(spacing: 8) {
                    DSTextField(
                        placeholder: "Paste AssemblyAI API key",
                        text: $settings.assemblyAIAPIKey,
                        isSecure: true
                    )
                    .frame(width: 280)
                    if !settings.assemblyAIAPIKey.isEmpty {
                        Button("Clear") { settings.assemblyAIAPIKey = "" }
                            .buttonStyle(.dsSecondary)
                    }
                }
            }
            DSDivider()
            DSInfoRow(label: "Status") {
                if settings.resolvedAssemblyAIAPIKey.isEmpty {
                    DSStatusPill(
                        text: "API key required",
                        dotColor: DS.Colors.textSecondary,
                        textColor: DS.Colors.textSecondary,
                        fill: DS.Colors.bgInset
                    )
                } else {
                    DSStatusPill(text: "API key configured")
                }
            }
            DSDivider()
            DSDetailRow(
                label: "Processing region",
                caption:
                    "Global chooses the lowest-latency region. US and EU keep audio and transcription processing in that data zone."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAIRegion,
                    options: AssemblyAIRegion.allCases,
                    title: \.displayName
                )
            }
            DSDivider()
            DSInfoRow(label: "Price", value: "$0.62 per hour of audio")
        }

        DSSection(overline: "Dictation") {
            DSDetailRow(
                label: "Language",
                caption:
                    "Choose the expected language. The API can also recognize code-switching, but this first version sends one language per request."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAILanguage,
                    options: AssemblyAILanguage.allCases,
                    title: \.displayName
                )
            }
            DSDivider()
            DSDetailRow(
                label: "Live preview",
                caption:
                    "Uses an installed Apple Speech language on-device when available. The final pasted transcript always comes from AssemblyAI."
            ) {
                Text("Automatic")
                    .font(DS.Fonts.ui(13.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            DSDivider()
            DSDetailRow(
                label: "Output",
                caption: settings.assemblyAIOutputMode == .polished
                    ? "Removes filler, resolves clear self-corrections, and applies punctuation before pasting."
                    : "Pastes the verbatim transcript; AssemblyAI still returns both versions."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAIOutputMode,
                    options: AssemblyAIOutputMode.allCases,
                    title: \.displayName
                )
            }
        }

        DSSection(overline: "Internal Prompts") {
            DSDetailRow(
                label: "Customize prompts",
                caption: "Edit AssemblyAI recognition, cleanup, destination, writing-style, and field-context instructions."
            ) {
                Button("Customize…") {
                    appState.selectedPage = .internalPrompts
                }
                .buttonStyle(.dsSecondary)
            }
        }

        CustomVocabularySection(
            terms: $settings.customVocabulary,
            footer:
                "Up to 100 names, product terms, and domain-specific phrases are sent as AssemblyAI keyterms. With remote context sharing enabled, destination terms are added for the current dictation only."
        )

        DSSection(overline: "Context Awareness") {
            DSStackedRow(
                label: "Adapt to the current app and text field",
                caption:
                    "Classifies the destination and sends that category to AssemblyAI. Password fields and excluded apps are never read.",
                isOn: $settings.dictationContextAwarenessEnabled
            )
            if settings.dictationContextAwarenessEnabled {
                DSDivider()
                DSStackedRow(
                    label: "Share app details and surrounding text with AssemblyAI",
                    caption:
                        "Off by default. App name, nearby text, and extracted terms stay on this Mac unless enabled and are never shared from password fields or excluded apps.",
                    isOn: $settings.shareDictationContextWithRemoteProviders
                )
            }
        }

        if settings.dictationContextAwarenessEnabled,
            settings.assemblyAIOutputMode == .polished
        {
            DSSection(overline: "Writing Style") {
                assemblyAIWritingStyleRow(settings: settings, category: .email)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .workMessaging)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .personalMessaging)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .other)
            }
        }

        DSHint(
            text:
                "AssemblyAI requires an internet connection and accepts recordings up to 120 seconds. Dictate Anywhere deletes its temporary local recovery copy after success; failed requests remain in History when that copy is available."
        )
    }

    private func assemblyAIWritingStyleRow(
        settings: Settings,
        category: DictationContextCategory
    ) -> some View {
        DSDetailRow(label: category.displayName, caption: assemblyAIStyleCaption(for: category)) {
            DSDropdown(
                selection: assemblyAIWritingStyleBinding(settings: settings, category: category),
                options: DictationWritingStyle.options(for: category),
                title: \.displayName
            )
        }
    }

    private func assemblyAIWritingStyleBinding(
        settings: Settings,
        category: DictationContextCategory
    ) -> Binding<DictationWritingStyle> {
        Binding(
            get: { settings.dictationWritingStyle(for: category) },
            set: { value in
                switch category {
                case .email: settings.emailDictationWritingStyle = value
                case .workMessaging: settings.workMessagingDictationWritingStyle = value
                case .personalMessaging: settings.personalMessagingDictationWritingStyle = value
                case .other: settings.otherDictationWritingStyle = value
                }
            }
        )
    }

    private func assemblyAIStyleCaption(for category: DictationContextCategory) -> String {
        switch category {
        case .email: return "Used in mail apps and webmail."
        case .workMessaging: return "Used in Slack, Teams, Discord, and similar work chat."
        case .personalMessaging:
            return "Used in Messages, WhatsApp, Telegram, and similar personal chat."
        case .other: return "Used when no email or messaging category matches."
        }
    }

    private var unsupportedAppleSpeechAlertTitle: String {
        AppleSpeechEngine.isOperatingSystemSupported
            ? "Apple Speech Isn’t Available on This Mac"
            : "Apple Speech Requires macOS 26"
    }

    private var unsupportedAppleSpeechAlertMessage: String {
        if !AppleSpeechEngine.isOperatingSystemSupported {
            return "\(AppleSpeechEngine.operatingSystemDisplayName) does not support Apple Speech. Update to macOS 26 or later to use it. FluidAudio remains available on this Mac."
        }
        return "Apple Speech is not available on this Mac. You can continue using FluidAudio."
    }

    @ViewBuilder
    private var appleSpeechStatusRow: some View {
        if appState.isPreparingEngine {
            DSInfoRow(label: "Preparing Apple Speech…") {
                ProgressView()
                    .controlSize(.small)
            }
        } else if appState.appleSpeechEngine.isReady {
            DSInfoRow(label: "Status") {
                DSStatusPill(text: "Ready")
            }
        } else {
            DSInfoRow(label: "Status") {
                HStack(spacing: 10) {
                    DSStatusPill(
                        text: "Not set up",
                        dotColor: DS.Colors.textSecondary,
                        textColor: DS.Colors.textSecondary,
                        fill: DS.Colors.bgInset
                    )
                    Button("Set Up Apple Speech") {
                        Task { await appState.prepareActiveEngine() }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(appState.status != .idle)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if appState.parakeetEngine.isModelDownloaded {
            DSInfoRow(label: "Status") {
                DSStatusPill(text: "Ready")
            }
        } else if appState.parakeetEngine.isDownloading {
            let progress = appState.parakeetEngine.downloadProgress
            DSInfoRow(label: "Downloading… \(Int(progress * 100))%") {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Colors.accent)
                    .frame(width: 180)
            }
        } else {
            DSInfoRow(label: "Status") {
                HStack(spacing: 10) {
                    DSStatusPill(
                        text: "Not downloaded",
                        dotColor: DS.Colors.textSecondary,
                        textColor: DS.Colors.textSecondary,
                        fill: DS.Colors.bgInset
                    )
                    Button("Download Model") {
                        downloadError = nil
                        Task {
                            do {
                                try await appState.parakeetEngine.downloadModel()
                                await MainActor.run {
                                    applyParakeetSelection(userInitiated: true)
                                }
                            } catch {
                                downloadError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(appState.status != .idle)
                }
            }
        }
    }

    private func applyParakeetSelection(userInitiated: Bool) {
        guard appState.status == .idle else { return }
        Task { await appState.handleParakeetModelSelectionChange(userInitiated: userInitiated) }
    }

    private func alternateInstalledModel(excluding selectedModel: ParakeetModelChoice) -> ParakeetModelChoice? {
        // Files for a model this Mac can't run may survive a migration — don't
        // advertise one the picker won't offer.
        ParakeetModelChoice.availableCases.first {
            $0 != selectedModel && appState.parakeetEngine.checkModelOnDisk(for: $0)
        }
    }
}

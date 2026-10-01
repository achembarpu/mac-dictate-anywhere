//
//  QuickVocabularyPanel.swift
//  Dictate Anywhere
//
//  Floating panel for quickly adding custom vocabulary words.
//

import AppKit
import SwiftUI

final class QuickVocabularyPanel {
    static let shared = QuickVocabularyPanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show()
    }

    func show() {
        if panel == nil {
            panel = createPanel()
        }
        guard let panel else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 408, height: 336),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Custom Vocabulary"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: QuickVocabularyView())
        return panel
    }
}

private struct QuickVocabularyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newTerm = ""
    private var settings: Settings { Settings.shared }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Teach the transcription engine new words, names, or phrases.")
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    DSTextField(
                        placeholder: "Add word or phrase…",
                        text: $newTerm,
                        accessibilityName: "Add custom vocabulary word or phrase"
                    )
                    .onSubmit { addTerm() }

                    Button("Add", action: addTerm)
                    .buttonStyle(.dsSecondary)
                    .disabled(VocabularyInputParser.terms(
                        from: newTerm,
                        existingTerms: settings.customVocabulary
                    ).isEmpty)
                }
            }
            .padding(.horizontal, DS.Spacing.rowHorizontal)
            .padding(.top, 16)
            .padding(.bottom, 14)

            DSDivider()

            if settings.customVocabulary.isEmpty {
                Spacer()
                DSEmptyState(systemImage: "text.book.closed", title: "No words added yet")
                Spacer()
            } else {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.customVocabulary, id: \.self) { term in
                            DSChip(text: term, onRemove: {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    settings.customVocabulary.removeAll { $0 == term }
                                }
                            })
                        }
                    }
                    .padding(16)
                }

                DSDivider()

                HStack {
                    Text("\(settings.customVocabulary.count) word\(settings.customVocabulary.count == 1 ? "" : "s")")
                        .font(DS.Fonts.ui(11.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, DS.Spacing.rowHorizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(minHeight: 240, idealHeight: 336)
        .background(DS.Colors.bgWindow)
    }

    private func addTerm() {
        let terms = VocabularyInputParser.terms(
            from: newTerm,
            existingTerms: Settings.shared.customVocabulary
        )
        guard !terms.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            Settings.shared.customVocabulary.append(contentsOf: terms)
        }
        newTerm = ""
    }
}

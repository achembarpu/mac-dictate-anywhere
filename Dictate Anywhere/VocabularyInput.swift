//
//  VocabularyInput.swift
//  Dictate Anywhere
//
//  Shared custom vocabulary parsing and chip UI.
//

import SwiftUI

enum VocabularyInputParser {
    static func terms(from input: String, existingTerms: [String]) -> [String] {
        var seen = Set(existingTerms)
        var parsedTerms: [String] = []

        for rawTerm in input.split(whereSeparator: {
            $0 == "," || $0 == "\u{FF0C}" || $0 == "\u{3001}" || $0.isNewline
        }) {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            parsedTerms.append(term)
        }

        return parsedTerms
    }
}

/// Shared design-system section for every provider that accepts custom terms.
/// Keeping the editing behavior here prevents cloud and local model pages from
/// drifting into subtly different vocabulary controls.
struct CustomVocabularySection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var terms: [String]
    let footer: String
    @State private var pendingTerm = ""

    var body: some View {
        DSSection(overline: "Custom Vocabulary") {
            VStack(alignment: .leading, spacing: 10) {
                if !terms.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(terms, id: \.self) { term in
                            DSChip(text: term, onRemove: {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    terms.removeAll { $0 == term }
                                }
                            })
                        }
                    }
                }

                HStack(spacing: 8) {
                    DSTextField(
                        placeholder: "Add word or phrase…", text: $pendingTerm,
                        accessibilityName: "Add custom vocabulary word or phrase"
                    )
                        .frame(width: 260)
                        .onSubmit { addTerms() }

                    Button("Add") { addTerms() }
                        .buttonStyle(.dsSecondary)
                        .disabled(pendingTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, DS.Spacing.rowHorizontal)

            DSDivider()
            DSCardCaption(text: footer)
        }
    }

    private func addTerms() {
        let additions = VocabularyInputParser.terms(from: pendingTerm, existingTerms: terms)
        guard !additions.isEmpty else { return }
        terms.append(contentsOf: additions)
        pendingTerm = ""
    }
}

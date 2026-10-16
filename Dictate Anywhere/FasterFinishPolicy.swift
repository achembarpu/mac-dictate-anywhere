import Foundation

/// Keep the experimental opt-in limited to combinations with measured value.
nonisolated enum FasterFinishPolicy {
    static func supportsCleanupDrafts(model: ParakeetModelChoice, previewsEnabled: Bool) -> Bool {
        switch model {
        case .parakeetEou320: return true
        case .compactEnglish, .nemotron1120, .nemotronMultilingual: return previewsEnabled
        default: return false
        }
    }

    static func supportsExactWindowReuse(model: ParakeetModelChoice, hasVocabulary: Bool) -> Bool {
        model == .englishOnly || (model == .compactEnglish && hasVocabulary)
    }
}

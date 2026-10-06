import XCTest
import SwiftUI
@testable import Dictate_Anywhere

@MainActor
final class CleanupPromptSettingsTests: XCTestCase {
    private var providerPrompts: [(key: String, defaultPrompt: String)] {
        [
            ("aiPostProcessingPrompt", Settings.recommendedAppleIntelligenceCleanupPrompt),
            ("ollamaPostProcessingPrompt", Settings.recommendedTranscriptCleanupPrompt),
            ("openRouterPostProcessingPrompt", Settings.recommendedTranscriptCleanupPrompt),
            ("openAICompatiblePostProcessingPrompt", Settings.recommendedTranscriptCleanupPrompt),
        ]
    }

    func testMissingAndBlankPromptsSaveProviderDefaults() throws {
        try withIsolatedDefaults { defaults in
            for (key, defaultPrompt) in providerPrompts {
                for savedPrompt: String? in [nil, "", " \n\t "] {
                    if let savedPrompt { defaults.set(savedPrompt, forKey: key) }
                    else { defaults.removeObject(forKey: key) }

                    XCTAssertEqual(Settings.loadCleanupPrompt(
                        from: defaults, forKey: key, defaultPrompt: defaultPrompt
                    ), defaultPrompt)
                    XCTAssertEqual(defaults.string(forKey: key), defaultPrompt)
                }
            }
        }
    }

    func testCustomPromptsArePreservedExactlyOnUpgradeAndReload() throws {
        try withIsolatedDefaults { defaults in
            let customPrompt = " \nKeep my technical terms and line breaks.\t "
            for (key, defaultPrompt) in providerPrompts {
                defaults.set(customPrompt, forKey: key)
                for _ in 0..<2 {
                    XCTAssertEqual(Settings.loadCleanupPrompt(
                        from: defaults, forKey: key, defaultPrompt: defaultPrompt
                    ), customPrompt)
                    XCTAssertEqual(defaults.string(forKey: key), customPrompt)
                }
            }
        }
    }

    func testSavedDefaultSurvivesLaterDefaultChanges() throws {
        try withIsolatedDefaults { defaults in
            for (key, defaultPrompt) in providerPrompts {
                _ = Settings.loadCleanupPrompt(from: defaults, forKey: key, defaultPrompt: defaultPrompt)
                XCTAssertEqual(Settings.loadCleanupPrompt(
                    from: defaults, forKey: key, defaultPrompt: "A future version's default."
                ), defaultPrompt)
                XCTAssertEqual(defaults.string(forKey: key), defaultPrompt)
            }
        }
    }

    func testEditorBindingsPersistResetsWithoutChangingOtherProviders() {
        @Bindable var settings = Settings.shared
        let bindings = [
            $settings.aiPostProcessingPrompt,
            $settings.ollamaPostProcessingPrompt,
            $settings.openRouterPostProcessingPrompt,
            $settings.openAICompatiblePostProcessingPrompt,
        ]
        let savedPrompts = bindings.map(\.wrappedValue)
        defer {
            for (binding, savedPrompt) in zip(bindings, savedPrompts) {
                binding.wrappedValue = savedPrompt
            }
        }

        for resetIndex in bindings.indices {
            for index in bindings.indices {
                bindings[index].wrappedValue = "Custom prompt for provider \(index)."
            }
            bindings[resetIndex].wrappedValue = providerPrompts[resetIndex].defaultPrompt
            for index in bindings.indices {
                let expected = index == resetIndex
                    ? providerPrompts[index].defaultPrompt : "Custom prompt for provider \(index)."
                XCTAssertEqual(bindings[index].wrappedValue, expected)
                XCTAssertEqual(UserDefaults.standard.string(forKey: providerPrompts[index].key), expected)
            }
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "CleanupPromptSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

import XCTest
import FluidAudio
@testable import Dictate_Anywhere

final class ModelCapabilityTests: XCTestCase {
    func testNeuralEngineCapabilityMatchesCompileTimeArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(Hardware.isArm64Process, "arm64 slice must report an arm64 process")
        XCTAssertTrue(Hardware.canUseAppleNeuralEngine, "arm64 build must be able to use the ANE")
        #else
        XCTAssertFalse(Hardware.isArm64Process, "non-arm64 slice must not report an arm64 process")
        XCTAssertFalse(
            Hardware.canUseAppleNeuralEngine,
            "a non-arm64 slice must be treated as ANE-incapable even under Rosetta on Apple Silicon")
        #endif
        XCTAssertEqual(Hardware.canUseAppleNeuralEngine, Hardware.isArm64Process)
    }

    func testNeuralEngineCapabilityMatchesFluidAudioPlatformGate() {
        XCTAssertEqual(
            Hardware.canUseAppleNeuralEngine,
            SystemInfo.isAppleSilicon,
            "capability must match FluidAudio's own unsupportedPlatform guard")
    }

    func testIntelPickerHidesNemotronMultilingualAndKeepsEverythingElse() {
        let intel = ParakeetModelChoice.availableCases(hasNeuralEngine: false)
        XCTAssertFalse(intel.contains(.nemotronMultilingual), "Nemotron multilingual cannot run on Intel")
        XCTAssertEqual(intel, ParakeetModelChoice.allCases.filter { $0 != .nemotronMultilingual },
                       "only the ANE-only model should be withheld on Intel")
    }

    func testAppleSiliconPickerOffersEveryModel() {
        XCTAssertEqual(
            ParakeetModelChoice.availableCases(hasNeuralEngine: true),
            ParakeetModelChoice.allCases)
    }

    func testIntelFallbackKeepsChineseOnSenseVoice() {
        XCTAssertEqual(
            ParakeetModelChoice.availableFallback(for: .chinese, hasNeuralEngine: false),
            .senseVoice)
    }

    func testIntelFallbackIsRunnableForEveryLanguage() {
        for language in SupportedLanguage.allCases {
            let fallback = ParakeetModelChoice.availableFallback(for: language, hasNeuralEngine: false)
            XCTAssertNotEqual(fallback, .nemotronMultilingual, "\(language) fell back to an Intel-incapable model")
            XCTAssertTrue(fallback.isAvailable(hasNeuralEngine: false))
            if language == .norwegian {
                XCTAssertFalse(fallback.supportsLanguage(language))
                XCTAssertTrue(ParakeetModelChoice.compatibleCatalogChoices(
                    for: language, hasNeuralEngine: false).isEmpty)
            } else {
                XCTAssertTrue(fallback.supportsLanguage(language), "\(language) lost language support on Intel")
            }
        }
    }

    func testSenseVoicePrecisionTracksNeuralEngineAvailability() {
        XCTAssertEqual(
            ParakeetEngine.senseVoiceEncoderPrecision,
            Hardware.canUseAppleNeuralEngine ? SenseVoiceEncoderPrecision.int8 : .fp32)
    }

    func testModelStreamingClassificationIsComplete() {
        let streaming: Set<ParakeetModelChoice> = [
            .parakeetEou320, .nemotron560, .nemotron1120,
            .nemotron2240, .nemotronMultilingual
        ]
        let batch: Set<ParakeetModelChoice> = [
            .multilingual, .multilingualUltra, .englishOnly, .compactEnglish, .senseVoice
        ]

        XCTAssertEqual(Set(ParakeetModelChoice.allCases), streaming.union(batch))
        XCTAssertTrue(streaming.isDisjoint(with: batch))
        XCTAssertTrue(streaming.allSatisfy(\.usesTrueStreaming))
        XCTAssertTrue(batch.allSatisfy { !$0.usesTrueStreaming })
    }

    func testPostProcessingContextSupportMatchesProviderTransport() {
        XCTAssertEqual(TranscriptPostProcessingMode.none.dictationContextSupport(), .none)
        XCTAssertEqual(TranscriptPostProcessingMode.fluidAudioVocabulary.dictationContextSupport(), .none)
        XCTAssertEqual(TranscriptPostProcessingMode.s1Mini.dictationContextSupport(), .categoryOnlyOnDevice)
        XCTAssertEqual(TranscriptPostProcessingMode.appleIntelligence.dictationContextSupport(), .fullOnDevice)
        XCTAssertEqual(
            TranscriptPostProcessingMode.ollama.dictationContextSupport(isConfiguredServerLocal: true),
            .fullLocalServer
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.openAICompatible.dictationContextSupport(isConfiguredServerLocal: false),
            .remoteCategoryWithOptionalText
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.openRouter.dictationContextSupport(isConfiguredServerLocal: true),
            .remoteCategoryWithOptionalText
        )

        XCTAssertFalse(DictationContextSupport.categoryOnlyOnDevice.includesCapturedText(remoteSharingEnabled: true))
        XCTAssertTrue(DictationContextSupport.fullOnDevice.includesCapturedText(remoteSharingEnabled: false))
        XCTAssertTrue(DictationContextSupport.fullLocalServer.includesCapturedText(remoteSharingEnabled: false))
        XCTAssertFalse(
            DictationContextSupport.remoteCategoryWithOptionalText.includesCapturedText(
                remoteSharingEnabled: false
            )
        )
        XCTAssertTrue(
            DictationContextSupport.remoteCategoryWithOptionalText.includesCapturedText(
                remoteSharingEnabled: true
            )
        )
    }

    func testNemotronLanguageCodes() {
        XCTAssertEqual(SupportedLanguage.chinese.nemotronLanguageCode, "zh-CN")
        XCTAssertEqual(SupportedLanguage.english.nemotronLanguageCode, "en-US")
        XCTAssertEqual(SupportedLanguage.german.nemotronLanguageCode, "de")
    }

    func testAppleSpeechPreviewMapsAssemblyAILanguageCodesToLocales() {
        XCTAssertEqual(AppleSpeechEngine.locale(forLanguageCode: "zh").identifier, "zh-CN")
        XCTAssertEqual(AppleSpeechEngine.locale(forLanguageCode: "yue").identifier, "yue-HK")
        XCTAssertEqual(
            AppleSpeechEngine.locale(forLanguageCode: "ja").language.languageCode?.identifier,
            "ja"
        )
    }

    func testProviderSpecificSidebarPagesFollowEngineCapabilities() {
        XCTAssertTrue(SidebarPage.internalPrompts.isVisible(for: .assemblyAI))
        XCTAssertFalse(SidebarPage.internalPrompts.isVisible(for: .appleSpeech))
        XCTAssertFalse(SidebarPage.internalPrompts.isVisible(for: .parakeet))
        XCTAssertFalse(SidebarPage.aiPostProcessing.isVisible(for: .assemblyAI))
        XCTAssertTrue(SidebarPage.aiPostProcessing.isVisible(for: .appleSpeech))
        XCTAssertTrue(SidebarPage.aiPostProcessing.isVisible(for: .parakeet))
    }

    func testMandarinModelLanguageRules() {
        XCTAssertNil(ParakeetModelChoice.senseVoice.selectableLanguages)
        XCTAssertNotNil(ParakeetModelChoice.senseVoice.fixedLanguageLabel)
        XCTAssertEqual(ParakeetModelChoice.nemotronMultilingual.selectableLanguages,
                       SupportedLanguage.allCases.filter { $0 != .maltese })
        XCTAssertEqual(Set(ParakeetModelChoice.multilingual.selectableLanguages ?? []),
                       Set(SupportedLanguage.allCases.filter { $0 != .chinese && $0 != .norwegian }))
        XCTAssertFalse(ParakeetModelChoice.multilingual.supportsLanguage(.chinese))
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.supportsLanguage(.chinese))
        XCTAssertTrue(ParakeetModelChoice.senseVoice.supportsLanguage(.chinese))
        XCTAssertFalse(ParakeetModelChoice.englishOnly.supportsLanguage(.chinese))
    }

    func testVocabularySupportMatchesAvailableDecoderPaths() {
        XCTAssertFalse(ParakeetModelChoice.senseVoice.supportsFluidAudioVocabulary)
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.supportsFluidAudioVocabulary)
        XCTAssertTrue(ParakeetModelChoice.multilingual.supportsFluidAudioVocabulary)
    }

    func testNativeStreamingDoesNotOfferUnusedCTCVocabularyFinalizer() {
        for model in ParakeetModelChoice.allCases where model.usesTrueStreaming && model != .nemotronMultilingual {
            XCTAssertFalse(model.supportsFluidAudioVocabulary, model.rawValue)
        }
        XCTAssertTrue(ParakeetModelChoice.multilingualUltra.supportsFluidAudioVocabulary)
        XCTAssertEqual(ParakeetModelChoice.multilingualUltra.selectableLanguages,
                       ParakeetModelChoice.multilingual.selectableLanguages)
        XCTAssertFalse(ParakeetModelChoice.multilingualUltra.usesTrueStreaming)
        XCTAssertTrue(ParakeetModelChoice.multilingualUltra.isAvailable(hasNeuralEngine: false))
    }
    func testCatalogConsolidatesNemotronWithoutDiscardingItsSavedPresets() {
        XCTAssertEqual(ParakeetModelChoice.catalogChoices.count, 8)
        XCTAssertEqual(Set(ParakeetModelChoice.catalogChoices).count, 8)
        for preset in [ParakeetModelChoice.nemotron560, .nemotron1120, .nemotron2240] {
            XCTAssertEqual(preset.catalogChoice, .nemotron560)
            XCTAssertEqual(ParakeetModelChoice.nemotron560.selectionPreservingPreset(preset), preset)
            XCTAssertEqual(ParakeetModelChoice(rawValue: preset.rawValue), preset)
        }
    }

    func testCatalogRecommendationsMatchLanguageAndHardware() {
        XCTAssertEqual(ParakeetModelChoice.recommendedCatalogChoices(
            for: .chinese, hasNeuralEngine: true), [.senseVoice, .nemotronMultilingual])
        XCTAssertEqual(ParakeetModelChoice.recommendedCatalogChoices(
            for: .chinese, hasNeuralEngine: false), [.senseVoice])
        XCTAssertEqual(ParakeetModelChoice.recommendedCatalogChoices(
            for: .norwegian, hasNeuralEngine: true), [.nemotronMultilingual])
        XCTAssertTrue(ParakeetModelChoice.recommendedCatalogChoices(
            for: .norwegian, hasNeuralEngine: false).isEmpty)
        XCTAssertEqual(ParakeetModelChoice.catalogLanguageOptions(
            preserving: .norwegian, hasNeuralEngine: false).first, .norwegian)
        XCTAssertFalse(ParakeetModelChoice.catalogLanguages(hasNeuralEngine: false).contains(.norwegian))
        XCTAssertEqual(ParakeetModelChoice.recommendedCatalogChoices(
            for: .english, hasNeuralEngine: true).first, .englishOnly)
        XCTAssertFalse(ParakeetModelChoice.compatibleCatalogChoices(
            for: .chinese, hasNeuralEngine: true).contains(.multilingualUltra))
    }

    func testParakeetLanguageSetOffersMalteseAndRejectsNorwegian() {
        for model in [ParakeetModelChoice.multilingual, .multilingualUltra] {
            XCTAssertEqual(Set(model.transcriptionLanguages).count, 25)
            XCTAssertTrue(model.supportsLanguage(.maltese))
            XCTAssertFalse(model.supportsLanguage(.norwegian))
        }
        XCTAssertFalse(ParakeetModelChoice.senseVoice.supportsLanguage(.maltese))
        XCTAssertFalse(ParakeetModelChoice.nemotronMultilingual.supportsLanguage(.maltese))
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.hasLimitedLanguageCoverage(.greek))
        XCTAssertNotNil(ParakeetModelChoice.nemotronMultilingual.languageSupportNotice(for: .greek))
        XCTAssertFalse(ParakeetModelChoice.recommendedCatalogChoices(
            for: .greek, hasNeuralEngine: true).contains(.nemotronMultilingual))
    }

}

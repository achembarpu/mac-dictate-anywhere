import XCTest
@testable import Dictate_Anywhere

/// Tests that exercise `Settings.shared` mutating APIs.
/// Every touched property is snapshotted in `setUp` and restored in `tearDown`
/// so the host app's persisted settings are left untouched.
final class SettingsLogicTests: XCTestCase {
    private var savedFillerEnabled = false
    private var savedFillerWords: [String] = []
    private var savedHistory: [TranscriptHistoryEntry] = []
    private var savedBindings: [HotkeyBinding] = []
    private var savedMode: TranscriptPostProcessingMode = .none
    private var savedEngineChoice: TranscriptionEngineChoice = .parakeet
    private var savedParakeetModelChoice: ParakeetModelChoice = .multilingual
    private var savedSelectedLanguage: SupportedLanguage = .english
    private var savedPendingVocabularyModeRestore = false
    private var savedContextAwarenessEnabled = true
    private var savedS1MiniStyling: S1MiniStyling = .semiFormal
    private var savedS1MiniAppStyling = S1MiniAppStyling.recommended
    private var savedAssemblyAIPromptOverrides: [String: String] = [:]
    private var savedAssemblyAIInstruction = ""

    override func setUp() {
        super.setUp()
        let settings = Settings.shared
        savedFillerEnabled = settings.isFillerWordRemovalEnabled
        savedFillerWords = settings.fillerWordsToRemove
        savedHistory = settings.transcriptHistory
        savedBindings = settings.hotkeyBindings
        savedMode = settings.transcriptPostProcessingMode
        savedEngineChoice = settings.engineChoice
        savedParakeetModelChoice = settings.parakeetModelChoice
        savedSelectedLanguage = settings.selectedLanguage
        savedPendingVocabularyModeRestore = settings.pendingVocabularyModeRestore
        savedContextAwarenessEnabled = settings.dictationContextAwarenessEnabled
        savedS1MiniStyling = settings.s1MiniStyling
        savedS1MiniAppStyling = settings.s1MiniAppStyling
        savedAssemblyAIPromptOverrides = settings.assemblyAIPromptOverrides
        savedAssemblyAIInstruction = settings.assemblyAIInstruction
    }

    override func tearDown() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = savedFillerEnabled
        settings.fillerWordsToRemove = savedFillerWords
        settings.transcriptHistory = savedHistory
        settings.hotkeyBindings = savedBindings
        settings.pendingVocabularyModeRestore = savedPendingVocabularyModeRestore
        settings.dictationContextAwarenessEnabled = savedContextAwarenessEnabled
        settings.s1MiniStyling = savedS1MiniStyling
        settings.s1MiniAppStyling = savedS1MiniAppStyling
        settings.resetAllAssemblyAIPrompts()
        for (rawPrompt, value) in savedAssemblyAIPromptOverrides {
            if let prompt = AssemblyAIInternalPrompt(rawValue: rawPrompt) {
                settings.setAssemblyAIPrompt(value, for: prompt)
            }
        }
        settings.assemblyAIInstruction = savedAssemblyAIInstruction
        // Restore engine/model choice before post-processing mode: both
        // carry didSet coercions that can rewrite `transcriptPostProcessingMode`
        // (and `selectedLanguage`), so mode must be restored last to avoid
        // being clobbered by a coercion firing during this teardown.
        settings.engineChoice = savedEngineChoice
        settings.parakeetModelChoice = savedParakeetModelChoice
        settings.selectedLanguage = savedSelectedLanguage
        settings.transcriptPostProcessingMode = savedMode
        super.tearDown()
    }


    func testChangingModelKeepsExpectedLanguageForExplicitCorrection() {
        let settings = Settings.shared
        settings.selectedLanguage = .norwegian
        settings.parakeetModelChoice = .multilingual
        XCTAssertEqual(settings.selectedLanguage, .norwegian)
        settings.parakeetModelChoice = .englishOnly
        XCTAssertEqual(settings.selectedLanguage, .norwegian)
    }

    func testUnsupportedStoredLanguageFailsBeforeModelOrMicrophoneStartup() async throws {
        let settings = Settings.shared
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .norwegian
        let engine = ParakeetEngine()
        do {
            try await engine.startRecording(deviceID: nil)
            XCTFail("An unsupported model/language pair must not start capture.")
        } catch TranscriptionError.speechModelLanguageUnsupported(let model, let language) {
            XCTAssertEqual(model, "Parakeet v3")
            XCTAssertEqual(language, "Norwegian")
        }
        XCTAssertFalse(engine.isDownloading)
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(settings.selectedLanguage, .norwegian, "Keep the preference visible for the user to resolve.")
    }

    func testHistoryDecodesOlderEntriesWithoutRawText() throws {
        let json = #"{"id":"5B5304DB-AD12-40AD-928B-43A113D1E9DE","text":"Older dictation","createdAt":811700095}"#
        let entry = try JSONDecoder().decode(TranscriptHistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.text, "Older dictation")
        XCTAssertNil(entry.rawText)
    }

    func testHistoryPersistsAndSearchesRawAndFinalText() async throws {
        let settings = Settings.shared
        settings.clearTranscriptHistory()
        settings.addTranscriptHistoryEntry("Rotation snapping is reversed.", rawText: "um snapping for rotation is reversed")
        await settings.flushTranscriptHistory()
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "transcriptHistory"))
        let restored = try JSONDecoder().decode([TranscriptHistoryEntry].self, from: data)
        XCTAssertEqual(restored.first?.text, "Rotation snapping is reversed.")
        XCTAssertEqual(restored.first?.rawText, "um snapping for rotation is reversed")
        XCTAssertEqual(TranscriptHistoryView.filteredEntries(restored, searchText: "UM SNAPPING").count, 1)
        XCTAssertEqual(TranscriptHistoryView.filteredEntries(restored, searchText: "Rotation snapping").count, 1)
        settings.removeTranscriptHistoryEntry(id: restored[0].id)
        await settings.flushTranscriptHistory()
        let deleted = try JSONDecoder().decode([TranscriptHistoryEntry].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "transcriptHistory")))
        XCTAssertTrue(deleted.isEmpty)
    }

    // MARK: - Filler word removal

    func testConfiguredFillersRespectCaseWordBoundariesAndPunctuation() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = ["um", "uh"]
        for (input, expected) in [
            ("So um I think uh this works", "So I think this works"),
            ("Um hello UM world", "hello world"),
            ("my umbrella um leaks", "my umbrella leaks"),
            ("Well um, fine um.", "Well, fine.")
        ] {
            XCTAssertEqual(settings.removeFillerWords(from: input), expected, input)
        }
    }

    func testFillerRemovalIsDisabledByToggleOrEmptyList() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = false
        settings.fillerWordsToRemove = ["um"]
        XCTAssertEqual(settings.removeFillerWords(from: "um hi"), "um hi")
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = []
        XCTAssertEqual(settings.removeFillerWords(from: "um hi"), "um hi")
    }

    func testAssemblyAIPromptsCanResetIndividuallyAndTogether() {
        let settings = Settings.shared
        settings.resetAllAssemblyAIPrompts()

        settings.setAssemblyAIPrompt("Use short email paragraphs.", for: .email)
        settings.setAssemblyAIPrompt("Use a warm voice.", for: .casual)
        settings.assemblyAIInstruction = "Keep product names unchanged."

        XCTAssertEqual(settings.assemblyAIPrompt(.email), "Use short email paragraphs.")
        XCTAssertTrue(settings.isAssemblyAIPromptCustomized(.email))

        settings.resetAssemblyAIPrompt(.email)
        XCTAssertEqual(settings.assemblyAIPrompt(.email), AssemblyAIInternalPrompt.email.defaultValue)
        XCTAssertFalse(settings.isAssemblyAIPromptCustomized(.email))
        XCTAssertTrue(settings.isAssemblyAIPromptCustomized(.casual))

        settings.resetAllAssemblyAIPrompts()
        XCTAssertEqual(settings.assemblyAIPrompt(.casual), AssemblyAIInternalPrompt.casual.defaultValue)
        XCTAssertEqual(settings.assemblyAIInstruction, "")
    }

    // MARK: - Hotkey bindings

    func testAddUpdateClearRemoveBinding() {
        let settings = Settings.shared
        settings.hotkeyBindings = [HotkeyBinding.defaultBinding]

        let added = settings.addBinding()
        XCTAssertEqual(settings.hotkeyBindings.count, 2)
        XCTAssertFalse(added.hasBinding)

        settings.updateBindingHotkey(
            id: added.id,
            keyCode: nil,
            modifiers: [.command, .shift],
            displayName: "\u{21E7}\u{2318}"
        )
        let updated = settings.hotkeyBindings.first { $0.id == added.id }
        XCTAssertEqual(updated?.displayName, "\u{21E7}\u{2318}")
        XCTAssertTrue(updated?.hasBinding ?? false)

        var modeChanged = updated!
        modeChanged.mode = .handsFreeToggle
        settings.updateBinding(modeChanged)
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == added.id }?.mode, .handsFreeToggle)

        settings.clearBindingHotkey(id: added.id)
        let cleared = settings.hotkeyBindings.first { $0.id == added.id }
        XCTAssertEqual(cleared?.hasBinding, false)

        settings.removeBinding(id: added.id)
        XCTAssertEqual(settings.hotkeyBindings.count, 1)
    }

    func testS1MiniStylingUsesSupportedAppCategoryControlsWithFallback() {
        let settings = Settings.shared
        settings.s1MiniStyling = .casual
        settings.s1MiniAppStyling = S1MiniAppStyling(
            email: .formal,
            workMessaging: .semiFormal,
            personalMessaging: .semiCasual,
            other: .semiFormal
        )

        settings.dictationContextAwarenessEnabled = true
        XCTAssertEqual(settings.s1MiniStyling(for: .email), .formal)
        XCTAssertEqual(settings.s1MiniStyling(for: .personalMessaging), .semiCasual)
        XCTAssertEqual(settings.s1MiniStyling(for: nil), .casual)

        settings.dictationContextAwarenessEnabled = false
        XCTAssertEqual(settings.s1MiniStyling(for: .email), .casual)
    }

    /// Switching engines away from Parakeet while a vocabulary-incapable
    /// Parakeet model is persisted must not leave a stale
    /// `.fluidAudioVocabulary` post-processing mode selected once the user
    /// switches back to Parakeet.
    func testEngineChoiceCoercesStaleVocabularyMode() {
        let settings = Settings.shared

        // Start on a Parakeet model that supports FluidAudio vocabulary.
        settings.parakeetModelChoice = .multilingual
        XCTAssertTrue(settings.parakeetModelChoice.supportsFluidAudioVocabulary)

        // Vocabulary mode is legitimate on Apple Speech, independent of the
        // persisted Parakeet model choice.
        settings.engineChoice = .appleSpeech
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary

        // Changing the persisted Parakeet model choice while the active
        // engine is Apple Speech must not coerce the mode away.
        settings.parakeetModelChoice = .senseVoice
        XCTAssertFalse(settings.parakeetModelChoice.supportsFluidAudioVocabulary)
        XCTAssertEqual(settings.transcriptPostProcessingMode, .fluidAudioVocabulary)

        // Switching the engine to Parakeet with a stale, vocab-incapable
        // model selected must coerce the mode back to `.none`.
        settings.engineChoice = .parakeet
        XCTAssertEqual(settings.transcriptPostProcessingMode, .none)
    }

    // MARK: - Pending vocabulary mode restore (auto-switch)

    func testAutoSwitchMarksOnlyStrippedVocabularyModeForRestoration() {
        let settings = Settings.shared
        for (hadVocabulary, mode, expected) in [
            (true, TranscriptPostProcessingMode.none, true),
            (false, .none, false), (true, .fluidAudioVocabulary, false)
        ] {
            settings.pendingVocabularyModeRestore = false
            settings.transcriptPostProcessingMode = mode
            settings.noteAutoSwitchModelChange(hadVocabularyMode: hadVocabulary)
            XCTAssertEqual(settings.pendingVocabularyModeRestore, expected, "had=\(hadVocabulary), mode=\(mode)")
        }
    }

    func testVocabularyRestorationWaitsForCapableModelAndRespectsUserChoice() {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        let cases: [(ParakeetModelChoice, TranscriptPostProcessingMode, Bool, TranscriptPostProcessingMode, Bool)] = [
            (.multilingual, .none, true, .fluidAudioVocabulary, false),
            (.senseVoice, .none, true, .none, true),
            (.multilingual, .ollama, true, .ollama, false),
            (.multilingual, .fluidAudioVocabulary, true, .fluidAudioVocabulary, false),
            (.multilingual, .none, false, .none, false)
        ]
        for (model, mode, pending, expectedMode, expectedPending) in cases {
            settings.parakeetModelChoice = model
            settings.transcriptPostProcessingMode = mode
            settings.pendingVocabularyModeRestore = pending
            settings.restoreVocabularyModeAfterAutoSwitchIfPending()
            XCTAssertEqual(settings.transcriptPostProcessingMode, expectedMode, "model=\(model), mode=\(mode)")
            XCTAssertEqual(settings.pendingVocabularyModeRestore, expectedPending)
        }
    }

    // MARK: - Theme mode

    func testThemeModeAppliesAppAppearance() {
        let settings = Settings.shared
        let savedTheme = settings.themeMode
        let savedAppearance = NSApp.appearance
        defer {
            settings.themeMode = savedTheme
            NSApp.appearance = savedAppearance
        }

        settings.themeMode = .dark
        XCTAssertEqual(settings.themeMode, .dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)

        settings.themeMode = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)

        settings.themeMode = .system
        XCTAssertNil(NSApp.appearance)
    }
}

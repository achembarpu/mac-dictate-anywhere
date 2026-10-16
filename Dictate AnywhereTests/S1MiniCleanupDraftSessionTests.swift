import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniCleanupDraftSessionTests: XCTestCase {
    private func configuration(revision: Int = 0, modelRevision: Int = 0) -> S1MiniCleanupDraftSession.Configuration {
        .init(modelURL: URL(fileURLWithPath: "/unused/model.gguf"), modelRevision: modelRevision,
              settingsRevision: revision, styling: .semiFormal, structure: .prose, context: "general")
    }

    // Protects the compute budget against fast ASR revisions, and verifies that
    // a trailing request uses the newest observed source rather than a queue.
    func testSparseScheduleCoalescesRevisionsAndBoundsContinuousSpeech() async {
        var requests: [String] = []
        let config = configuration()
        let session = S1MiniCleanupDraftSession(now: 0) { source, _ in
            requests.append(source)
            return source
        }
        for tick in 0...2_000 {
            let now = Double(tick) / 10
            // Continuous text never reaches the stability threshold; periodic
            // opportunities still occur without knowledge of recording length.
            session.update(source: "revision \(tick)", configuration: config, now: now)
            await session.join()
        }
        XCTAssertEqual(requests.first, "revision 100")
        XCTAssertEqual(requests.last, "revision 1500")
        XCTAssertEqual(requests.count, 15)
        session.cancel()
        await session.join()

        var stableSources: [String] = []
        let stable = S1MiniCleanupDraftSession(now: 0) { source, _ in
            stableSources.append(source)
            return source
        }
        stable.update(source: "old", configuration: config, now: 0)
        stable.update(source: "latest", configuration: config, now: 7)
        stable.update(source: "latest", configuration: config, now: 8)
        await stable.join()
        for tick in 81...160 {
            stable.update(source: "latest", configuration: config, now: Double(tick) / 10)
        }
        XCTAssertEqual(stableSources, ["latest"], "Unchanged text must not be cleaned repeatedly")
        stable.cancel()
        await stable.join()
    }

    // A saved opt-in must stop authorizing background work when the selected
    // engine/model/language/cleanup changes, without losing the preference.
    func testSelectionChangesSuspendSavedOptInAndRejectTheEarlierDraft() async {
        let settings = Settings.shared
        let saved = (settings.engineChoice, settings.parakeetModelChoice, settings.selectedLanguage,
                     settings.transcriptPostProcessingMode, settings.fasterFinishEnabled)
        defer {
            settings.engineChoice = saved.0
            settings.parakeetModelChoice = saved.1
            settings.selectedLanguage = saved.2
            settings.transcriptPostProcessingMode = saved.3
            settings.fasterFinishEnabled = saved.4
        }
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .parakeetEou320
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .s1Mini
        settings.fasterFinishEnabled = true
        var requests: [String] = []
        let session = S1MiniCleanupDraftSession(now: 0) { source, _ in
            requests.append(source)
            return source
        }
        func currentConfiguration() -> S1MiniCleanupDraftSession.Configuration? {
            settings.supportsS1MiniCleanupDrafts && settings.fasterFinishEnabled
                ? configuration(revision: settings.s1MiniDraftRevision) : nil
        }
        let original = currentConfiguration()
        session.update(source: "first preview", configuration: original, now: 0)
        session.update(source: "first preview", configuration: original, now: 8)
        await session.join()
        settings.engineChoice = .appleSpeech
        session.update(source: "Apple preview", configuration: currentConfiguration(), now: 16)
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .nemotron560
        session.update(source: "Nemotron preview", configuration: currentConfiguration(), now: 24)
        settings.parakeetModelChoice = .parakeetEou320
        settings.selectedLanguage = .german
        session.update(source: "other language", configuration: currentConfiguration(), now: 32)
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .none
        session.update(source: "no S1-mini", configuration: currentConfiguration(), now: 40)
        await session.join()
        XCTAssertEqual(requests, ["first preview"])
        XCTAssertTrue(settings.fasterFinishEnabled, "Switching a selection must preserve the opt-in preference")
        settings.transcriptPostProcessingMode = .s1Mini
        session.update(source: "eligible again", configuration: currentConfiguration(), now: 48)
        session.update(source: "eligible again", configuration: currentConfiguration(), now: 49)
        await session.join()
        let candidate = session.freeze()
        XCTAssertEqual(requests, ["first preview", "eligible again"])
        XCTAssertEqual(candidate?.output(matching: currentConfiguration()), "eligible again")
        XCTAssertNil(candidate?.output(matching: original))
    }

    // A saved opt-in must not add inference for unmeasured models, hidden batch
    // previews, empty vocabulary, or unsupported language/cleanup combinations.
    func testExperimentalSelectionEnablesOnlySupportedWork() {
        let settings = Settings.shared
        let saved = (settings.engineChoice, settings.parakeetModelChoice, settings.selectedLanguage,
                     settings.transcriptPostProcessingMode, settings.showTextPreview, settings.customVocabulary)
        defer {
            settings.engineChoice = saved.0
            settings.parakeetModelChoice = saved.1
            settings.selectedLanguage = saved.2
            settings.transcriptPostProcessingMode = saved.3
            settings.showTextPreview = saved.4
            settings.customVocabulary = saved.5
        }
        settings.engineChoice = .parakeet
        settings.selectedLanguage = .english
        settings.showTextPreview = true
        settings.customVocabulary = ["Zephyr"]
        settings.transcriptPostProcessingMode = .s1Mini
        for model in ParakeetModelChoice.allCases {
            settings.parakeetModelChoice = model
            XCTAssertEqual(settings.supportsS1MiniCleanupDrafts,
                           [.parakeetEou320, .compactEnglish, .nemotron1120, .nemotronMultilingual].contains(model),
                           model.rawValue)
            XCTAssertEqual(settings.supportsExactWindowReuse, model == .englishOnly, model.rawValue)
        }
        settings.parakeetModelChoice = .compactEnglish
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        XCTAssertFalse(settings.supportsS1MiniCleanupDrafts)
        XCTAssertTrue(settings.supportsExactWindowReuse)
        settings.customVocabulary = []
        XCTAssertFalse(settings.supportsFasterFinish)
        settings.customVocabulary = ["Zephyr"]
        settings.showTextPreview = false
        XCTAssertFalse(settings.supportsFasterFinish)
        settings.showTextPreview = true
        settings.selectedLanguage = .german
        XCTAssertFalse(settings.supportsFasterFinish)
        settings.selectedLanguage = .english
        settings.engineChoice = .appleSpeech
        XCTAssertFalse(settings.supportsFasterFinish)
    }

    // A native decode may ignore cancellation until its current call returns.
    // Cancellation must retain ownership, reject its late result, and join it.
    func testCancellationJoinsUncooperativeWorkAndDoesNotPublishIt() async {
        let probe = DraftProbe()
        let started = expectation(description: "request started")
        probe.onStart = { started.fulfill() }
        let session = S1MiniCleanupDraftSession(now: 0, process: probe.process)
        session.update(source: "preview", configuration: configuration(), now: 0)
        session.update(source: "preview", configuration: configuration(), now: 8)
        await fulfillment(of: [started], timeout: 2)
        session.cancel()
        var joined = false
        let joining = Task { await session.join(); joined = true }
        await Task.yield()
        XCTAssertFalse(joined)
        probe.finish("late output")
        await joining.value
        XCTAssertTrue(joined)
        XCTAssertNil(session.freeze())
        session.update(source: "next session", configuration: configuration(), now: 40)
        XCTAssertEqual(probe.sources, ["preview"])
    }

    // Stop may reuse an older completed draft, but never a request finishing
    // after Stop. Full final ASR is separately verified by the real-model test.
    func testStopFreezesCompletedOutputBeforeJoiningTheTrailingRequest() async {
        let probe = DraftProbe()
        let session = S1MiniCleanupDraftSession(now: 0, process: probe.process)
        let config = configuration()
        let first = expectation(description: "first started")
        probe.onStart = { first.fulfill() }
        session.update(source: "partial", configuration: config, now: 0)
        session.update(source: "partial", configuration: config, now: 8)
        await fulfillment(of: [first], timeout: 2)
        probe.finish("completed draft")
        await session.join()
        let second = expectation(description: "trailing started")
        probe.onStart = { second.fulfill() }
        session.update(source: "partial plus tail", configuration: config, now: 15)
        session.update(source: "partial plus tail", configuration: config, now: 16)
        await fulfillment(of: [second], timeout: 2)
        let candidate = session.freeze()
        probe.finish("too late")
        await session.join()
        XCTAssertEqual(candidate?.output(matching: config), "completed draft")
        XCTAssertNil(candidate?.output(matching: configuration(revision: 1)))
        XCTAssertNil(candidate?.output(matching: configuration(modelRevision: 1)))
    }

    // Changing controls must reject both a cached result and a late old request;
    // a replacement cannot overlap that request or replenish the launch budget.
    func testControlChangesCancelOldWorkAndKeepOnlyTheNewConfiguration() async {
        let probe = DraftProbe()
        let session = S1MiniCleanupDraftSession(now: 0, process: probe.process)
        let old = configuration()
        let new = configuration(revision: 1)
        let started = expectation(description: "old request started")
        probe.onStart = { started.fulfill() }
        session.update(source: "preview", configuration: old, now: 0)
        session.update(source: "preview", configuration: old, now: 8)
        await fulfillment(of: [started], timeout: 2)
        session.update(source: "preview", configuration: new, now: 16)
        XCTAssertEqual(probe.sources.count, 1)
        probe.finish("old controls")
        await session.join()
        let replacement = expectation(description: "replacement started")
        probe.onStart = { replacement.fulfill() }
        session.update(source: "newest preview", configuration: new, now: 17)
        session.update(source: "newest preview", configuration: new, now: 18)
        await fulfillment(of: [replacement], timeout: 2)
        probe.finish("new controls")
        await session.join()
        let candidate = session.freeze()
        XCTAssertEqual(probe.sources, ["preview", "newest preview"])
        XCTAssertEqual(candidate?.output(matching: new), "new controls")
        XCTAssertNil(candidate?.output(matching: old))
    }

    // This includes off/on between polls: matching visible controls must not
    // resurrect work produced before the user disabled the setting.
    func testDisablingMidRecordingCancelsWorkAndInvalidatesDisableReenableDrafts() async {
        let settings = Settings.shared
        let saved = settings.fasterFinishEnabled
        defer { settings.fasterFinishEnabled = saved }
        settings.fasterFinishEnabled = true
        let old = configuration(revision: settings.s1MiniDraftRevision)
        let probe = DraftProbe()
        let session = S1MiniCleanupDraftSession(now: 0, process: probe.process)
        let started = expectation(description: "request started")
        probe.onStart = { started.fulfill() }
        session.update(source: "preview", configuration: old, now: 0)
        session.update(source: "preview", configuration: old, now: 8)
        await fulfillment(of: [started], timeout: 2)
        settings.fasterFinishEnabled = false
        session.update(source: "preview", configuration: nil, now: 9)
        probe.finish("disabled result")
        await session.join()
        for now in [20.0, 40.0, 80.0] {
            session.update(source: "new tail", configuration: nil, now: now)
        }
        XCTAssertEqual(probe.sources.count, 1)
        XCTAssertNil(session.freeze())

        let cached = S1MiniCleanupDraftSession(now: 0) { _, _ in "cached output" }
        cached.update(source: "preview", configuration: old, now: 0)
        cached.update(source: "preview", configuration: old, now: 8)
        await cached.join()
        settings.fasterFinishEnabled = true
        let current = configuration(revision: settings.s1MiniDraftRevision)
        XCTAssertNil(cached.freeze()?.output(matching: current))
    }
}

@MainActor
private final class DraftProbe {
    var sources: [String] = []
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<String, Never>?

    func process(_ source: String, _ configuration: S1MiniCleanupDraftSession.Configuration) async throws -> String {
        sources.append(source)
        return await withCheckedContinuation {
            continuation = $0
            onStart?()
        }
    }

    func finish(_ output: String) {
        continuation?.resume(returning: output)
        continuation = nil
    }
}

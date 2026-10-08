import XCTest
import FluidAudio
@testable import Dictate_Anywhere

/// Protect cached-model upgrades: missing optional VAD must neither block
/// offline preparation nor prevent the batch session from finishing audio.
@MainActor
final class OfflineBatchPreparationTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_RECOVERY_ASR_TESTS"] == "1",
                          "Set RUN_RECOVERY_ASR_TESTS=1 to check offline upgrades with installed speech models")
    }

    func testCachedParakeetWorksWithoutSpeechDetectionOffline() async throws {
        try await checkOfflineModel(.englishOnly, fixture: "en-recovery") { text in
            let words = text.lowercased().split { !$0.isLetter }
            XCTAssertEqual(words.filter { $0 == "weather" }.count, 2, "Beginning missing: \(text)")
            XCTAssertEqual(words.filter { $0 == "cancellation" }.count, 2, "Tail missing: \(text)")
        }
    }

    func testCachedSenseVoiceWorksWithoutSpeechDetectionOffline() async throws {
        try await checkOfflineModel(.senseVoice, fixture: "zh-long") { text in
            // Two copies exceed the decoder's 30s limit. Each copy contains
            // four lead-in sentences; allow one seam variation, but reject
            // losing either half or the final tail.
            XCTAssertGreaterThanOrEqual(text.components(separatedBy: "生活方式").count - 1, 7,
                                        "Beginning or tail missing: \(text)")
            XCTAssertNil(text.range(of: #"\p{Han}\s+\p{Han}"#, options: .regularExpression),
                         "Segment joins inserted spaces between Han characters: \(text)")
        }
    }

    private func checkOfflineModel(_ model: ParakeetModelChoice, fixture: String,
                                   checkTranscript: (String) -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vadDirectory = directory.appendingPathComponent(Repo.vad.folderName)
        let missingVAD = vadDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        let engine = ParakeetEngine(vadModelURL: missingVAD)
        try XCTSkipUnless(engine.checkModelOnDisk(for: model), "\(model.displayName) is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        let oldMode = settings.transcriptPostProcessingMode
        let oldOffline = ModelHub.offlineMode
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            settings.transcriptPostProcessingMode = oldMode
            ModelHub.offlineMode = oldOffline
            try? FileManager.default.removeItem(at: directory)
        }
        settings.parakeetModelChoice = model
        settings.selectedLanguage = model == .senseVoice ? .chinese : .english
        settings.transcriptPostProcessingMode = .none
        ModelHub.offlineMode = true

        try await engine.prepare()
        XCTAssertTrue(engine.isReady, "Installed speech model cannot prepare without VAD")
        XCTAssertFalse(engine.isSpeechDetectionDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vadDirectory.path),
                       "Preparation must not create or download a missing VAD cache")
        do {
            try await engine.downloadSpeechDetection()
            XCTFail("Missing VAD cannot be downloaded with networking disabled")
        } catch {
            XCTAssertTrue(engine.isReady, "A failed optional download disabled cached dictation")
            XCTAssertFalse(engine.isSpeechDetectionDownloaded)
        }
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "wav"))
        let store = DictationRecoveryStore(directory: directory.appendingPathComponent("recovery"))
        let capture = try store.beginCapture()
        for _ in 0..<2 {
            let reader = try RecoveryAudioReader(url: audio)
            while let samples = try reader.nextSamples(maxSamples: 16_000) { capture.append(samples) }
        }
        let preserved = try await store.preserve(capture, preview: "", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        let text = try await engine.transcribeRecording(at: store.audioURL(id: entry.id))
        checkTranscript(text)
        await engine.cancel()
    }
}

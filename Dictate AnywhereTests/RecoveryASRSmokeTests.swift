import XCTest
@preconcurrency import AVFoundation
import Speech
import FluidAudio
@testable import Dictate_Anywhere

/// Exercises the actual file-recovery paths with a known speech fixture and
/// already-installed models. No microphone capture or model downloads.
@MainActor
final class RecoveryASRSmokeTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_RECOVERY_ASR_TESTS"] == "1",
                          "Set RUN_RECOVERY_ASR_TESTS=1 to test recovery with installed speech models")
    }

    func testBufferedModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .englishOnly)
    }

    func testStreamingModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .parakeetEou320)
    }

    func testMultilingualModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .multilingual)
    }

    func testNemotronModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .nemotron1120)
    }

    /// Exercise the same sliding-window/vocabulary configuration used for final
    /// dictation, without microphone access or the app's fallback hiding errors.
    func testVocabularyWindowsPreserveBeginningAndEnding() async throws {
        try XCTSkipUnless(ParakeetEngine().checkModelOnDisk(for: .englishOnly), "English Parakeet is not installed")
        let ctcDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ctcDirectory.path), "CTC model is not installed")
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        let ctcModels = try await CtcModels.load(from: ctcDirectory)
        let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
        let vocabulary = CustomVocabularyContext(terms: [
            CustomVocabularyTerm(text: "cancellation", ctcTokenIds: tokenizer.encode("cancellation"))
        ])
        let manager = SlidingWindowAsrManager(config: SlidingWindowAsrConfig(
            chunkSeconds: 11.0, hypothesisChunkSeconds: 1.0,
            leftContextSeconds: 2.0, rightContextSeconds: 2.0,
            minContextForConfirmation: 0.0, confirmationThreshold: 0.0))
        do {
            try await manager.configureVocabularyBoosting(
                vocabulary: vocabulary, ctcModels: ctcModels,
                config: ParakeetEngine.vocabularyRescorerConfig)
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .microphone)
            let fixture = try fixtureSamples()
            let samples = fixture + [Float](repeating: 0, count: 8_000) + fixture
            XCTAssertGreaterThan(samples.count, 11 * 16_000, "Fixture must exercise multiple windows")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            for offset in stride(from: 0, to: samples.count, by: 16_000) {
                let chunk = Array(samples[offset..<min(offset + 16_000, samples.count)])
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.count)
                }
                await manager.streamAudio(buffer)
            }
            let text = try await manager.finish()
            await manager.cleanup()
            print("VOCABULARY_ASR: \(text)")
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            XCTAssertEqual(words.filter { $0 == "weather" }.count, 2, "A beginning was lost: \(text)")
            XCTAssertEqual(words.filter { $0 == "recording" }.count, 2, "Ordinary words were replaced: \(text)")
            XCTAssertEqual(words.filter { $0 == "cancellation" }.count, 2, "Vocabulary was inserted or an ending lost: \(text)")
        } catch {
            await manager.cleanup()
            throw error
        }
    }

    private func checkFluidAudioRecovery(model: ParakeetModelChoice) async throws {
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: model), "\(model.displayName) is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        let oldMode = settings.transcriptPostProcessingMode
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            settings.transcriptPostProcessingMode = oldMode
        }
        settings.parakeetModelChoice = model
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .none
        try await engine.prepare()
        try await checkRecovery(using: engine)
    }

    func testAppleSpeechRecoversSavedAudio() async throws {
        try XCTSkipUnless(AppleSpeechEngine.isSupported, "Apple Speech is unavailable")
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized,
                          "Apple Speech permission has not been granted to the test app")
        let installed = await AppleSpeechEngine.installedLanguages()
        try XCTSkipUnless(installed.contains(.english), "English Apple Speech assets are not installed")
        let oldLanguage = Settings.shared.appleSpeechLanguage
        defer { Settings.shared.appleSpeechLanguage = oldLanguage }
        Settings.shared.appleSpeechLanguage = .english
        try await checkRecovery(using: AppleSpeechEngine())
    }

    private func checkRecovery(using engine: TranscriptionEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-asr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let capture = try store.beginCapture()
        capture.append(try fixtureSamples())
        _ = try await store.preserve(capture, preview: "", completedTranscript: nil)
        let relaunched = DictationRecoveryStore(directory: directory)
        try relaunched.reload()
        let entry = try XCTUnwrap(relaunched.entries.first)
        let text = try await engine.transcribeRecording(at: relaunched.audioURL(id: entry.id))
        print("RECOVERY_ASR \(type(of: engine)): \(text)")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("weather"), "Beginning of recording missing: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("cancellation"), "End of recording missing: \(text)")
    }

    private func fixtureSamples() throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "en-recovery", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !fed else { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

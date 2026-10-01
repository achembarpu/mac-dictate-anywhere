import XCTest
@preconcurrency import AVFoundation
import Speech
import FluidAudio
import CoreML
import os
@testable import Dictate_Anywhere

/// Exercises the actual file-recovery paths with a known speech fixture and
/// already-installed models. No microphone capture or model downloads.
@MainActor
final class RecoveryASRSmokeTests: XCTestCase {
    override func setUp() async throws {
        let recoveryEnabled = ProcessInfo.processInfo.environment["RUN_RECOVERY_ASR_TESTS"] == "1"
        #if PIPELINE_BENCHMARK
        let benchmarkEnabled = true
        #else
        let benchmarkEnabled = false
        #endif
        try XCTSkipUnless(recoveryEnabled || benchmarkEnabled,
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

    func testEveryInstalledModelIsPreparedOnceAndWarmupCannotLeakIntoDictation() async throws {
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        defer { settings.parakeetModelChoice = oldChoice; settings.transcriptPostProcessingMode = oldMode }
        settings.transcriptPostProcessingMode = .none
        for model in ParakeetModelChoice.availableCases {
            let engine = ParakeetEngine()
            guard hasInstalledBenchmarkModel(model, engine: engine) else { continue }
            settings.parakeetModelChoice = model
            try await engine.prepare()
            XCTAssertTrue(engine.isReady, model.rawValue)
            #if DEBUG
            let events = OSAllocatedUnfairLock(initialState: [String]())
            PerfTrace.onIntervalCompleted = { name, _, _ in
                if name == "stt.modelLoad" || name == "stt.modelWarmup" {
                    events.withLock { $0.append(name) }
                }
            }
            #endif
            try await engine.prepare()
            #if DEBUG
            PerfTrace.onIntervalCompleted = nil
            XCTAssertTrue(events.withLock { $0.isEmpty }, "Repeated preparation reloaded or rewarmed \(model.rawValue)")
            #endif
            XCTAssertEqual(engine.currentTranscript, "", model.rawValue)
            let id = model == .senseVoice ? "golden-zh-1" : "golden-en-1"
            let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == id })
            let output = try await engine.transcribeRecording(at: fixture.audioURL)
            XCTAssertFalse(output.isEmpty, model.rawValue)
            XCTAssertLessThan(try fixture.errorRate(hypothesis: output), 0.5, "Warmup contaminated \(model.rawValue): \(output)")
            await engine.cancel()
        }
    }

    /// Explicit opt-in only. Uses the app's downloader and its persistent cache,
    /// so installed artifacts are immediately reusable by normal app sessions.
    func testDownloadModelsIntoApplicationCache() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Model installation is an explicitly opted-in benchmark setup step")
        #else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PIPELINE_BENCHMARK_DOWNLOAD_MODELS"] == "1", "Set PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 to install models into the app cache")
        let name = environment["PIPELINE_BENCHMARK_MODEL"] ?? "all"
        let models = name == "all" ? ParakeetModelChoice.allCases : [try XCTUnwrap(ParakeetModelChoice(rawValue: name))]
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        defer { settings.parakeetModelChoice = oldChoice }
        for model in models where model.isAvailableOnThisMac {
            settings.parakeetModelChoice = model
            let engine = ParakeetEngine()
            let existed = hasInstalledBenchmarkModel(model, engine: engine)
            if existed { try await engine.prepare() }
            else { try await engine.downloadModel() }
            XCTAssertTrue(engine.isReady, model.rawValue)
            XCTAssertTrue(hasInstalledBenchmarkModel(model, engine: engine), model.rawValue)
            print("MODEL_CACHE_INSTALL model=\(model.rawValue) reused=\(existed) cache=\(benchmarkModelRoot.path)")
            await engine.cancel()
        }
        #endif
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

    func testV2VocabularyFinalizerPreservesShiftedGoldenSeam() async throws {
        let engine = ParakeetEngine()
        try XCTSkipUnless(hasInstalledBenchmarkModel(.englishOnly, engine: engine), "Install v2 and VAD")
        let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == "golden-en-boundaries" })
        let reader = try RecoveryAudioReader(url: fixture.audioURL)
        var audio: [Float] = []
        while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice, oldMode = settings.transcriptPostProcessingMode
        let oldVocabulary = settings.customVocabulary
        defer {
            settings.parakeetModelChoice = oldModel
            settings.transcriptPostProcessingMode = oldMode
            settings.customVocabulary = oldVocabulary
        }
        settings.parakeetModelChoice = .englishOnly
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.customVocabulary = ["John Collier", "Macbeth"]
        try await engine.prepare()
        for shift in [0, 8_000, 16_000] {
            let input = [Float](repeating: 0, count: shift) + audio
            try await engine.beginBatchReplayForTesting()
            for offset in stride(from: 0, to: input.count, by: 8_000) {
                try await engine.replayBatchAudioForTesting(Array(input[offset..<min(offset + 8_000, input.count)]))
            }
            let result = await engine.stopRecording()
            XCTAssertTrue(result.lowercased().contains("cheerful"), "Clear seam speech was lost: \(result)")
            XCTAssertLessThanOrEqual(try fixture.errorRate(hypothesis: result), 0.06, result)
        }
    }

    func testBatchCancellationAndShortFinalTailDoNotCarryBetweenRecordings() async throws {
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: .multilingual), "Multilingual Parakeet is not installed")
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        defer { settings.parakeetModelChoice = oldChoice; settings.transcriptPostProcessingMode = oldMode }
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .none
        try await engine.prepare()
        let fixture = try fixtureSamples()
        try await engine.beginBatchReplayForTesting()
        // Also cancel after enough audio to populate an authoritative SDK window.
        try await engine.replayBatchAudioForTesting(fixture + fixture)
        await engine.cancel()
        try await engine.beginBatchReplayForTesting()
        try await engine.replayBatchAudioForTesting([Float](repeating: 0, count: 8_000))
        let silence = await engine.stopRecording()
        XCTAssertEqual(silence, "", "Cancelled audio leaked into the next session")
        try await engine.beginBatchReplayForTesting()
        for offset in stride(from: 0, to: fixture.count, by: 8_000) {
            try await engine.replayBatchAudioForTesting(Array(fixture[offset..<min(offset + 8_000, fixture.count)]))
        }
        // Changing the preference must not switch the active recording's decoder.
        settings.parakeetModelChoice = .parakeetEou320
        let final = await engine.stopRecording().lowercased()
        XCTAssertTrue(final.contains("weather"), "Beginning missing: \(final)")
        XCTAssertTrue(final.contains("cancellation"), "Short final window lost its ending: \(final)")
    }

    func testQuietHumanSpeechIsDecodedWithoutAmplificationAndNoiseStaysEmpty() async throws {
        let engine = ParakeetEngine()
        try XCTSkipUnless(hasInstalledBenchmarkModel(.multilingual, engine: engine), "Install v3 and Silero VAD")
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        defer { settings.parakeetModelChoice = oldChoice; settings.transcriptPostProcessingMode = oldMode }
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .none
        try await engine.prepare()
        let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == "golden-nl-2" })
        let reader = try RecoveryAudioReader(url: fixture.audioURL)
        var audio: [Float] = []
        while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
        XCTAssertFalse(engine.batchReplayContainsSignificantAudioForTesting(audio), "This must exercise the quiet-speech fallback")
        try await engine.beginBatchReplayForTesting()
        for offset in stride(from: 0, to: audio.count, by: 8_000) {
            try await engine.replayBatchAudioForTesting(Array(audio[offset..<min(offset + 8_000, audio.count)]))
        }
        let text = await engine.stopRecording()
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThanOrEqual(try fixture.errorRate(hypothesis: text), 0.2)

        // A quiet steady mechanical tone has no speech. Keep it below the old
        // volume gate, so classification rather than volume determines eligibility.
        let tone = (0..<32_000).map { Float(sin(Double($0) * 2 * .pi * 120 / 16_000)) * 0.003 }
        try await engine.beginBatchReplayForTesting()
        for offset in stride(from: 0, to: tone.count, by: 8_000) {
            try await engine.replayBatchAudioForTesting(Array(tone[offset..<offset + 8_000]))
        }
        let noise = await engine.stopRecording()
        XCTAssertEqual(noise, "")
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
        let installed = await AppleSpeechEngine.installedLanguages()
        try XCTSkipUnless(installed.contains(.english), "English Apple Speech assets are not installed")
        let oldLanguage = Settings.shared.appleSpeechLanguage
        defer { Settings.shared.appleSpeechLanguage = oldLanguage }
        Settings.shared.appleSpeechLanguage = .english
        try await checkRecovery(using: AppleSpeechEngine())
    }

    /// Replays one saved speech fixture through the real offline transcription
    /// paths. Gated because it requires installed models and is intentionally
    /// slower than the normal test suite.
    func testRepeatableOfflineASRBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable the offline ASR benchmark")
        #else
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let capture = try store.beginCapture()
        capture.append(try fixtureSamples())
        let preserved = try await store.preserve(capture, preview: "", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        let audioURL = store.audioURL(id: entry.id)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        let oldAppleSpeechLanguage = settings.appleSpeechLanguage
        let oldMode = settings.transcriptPostProcessingMode
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            settings.appleSpeechLanguage = oldAppleSpeechLanguage
            settings.transcriptPostProcessingMode = oldMode
            PerfTrace.clearSessionMetadata()
        }

        let choice = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_MODEL"] ?? "parakeetEou320"
        let models: [ParakeetModelChoice]
        if choice == "all" {
            models = ParakeetModelChoice.allCases.filter { $0.isAvailableOnThisMac }
        } else {
            models = [try XCTUnwrap(ParakeetModelChoice(rawValue: choice), "Unknown benchmark model: \(choice)")]
        }
        var didRun = false
        for model in models {
            PerfTrace.clearSessionMetadata()
            let engine = ParakeetEngine()
            guard engine.checkModelOnDisk(for: model) else {
                print("REPRO_ASR_BENCHMARK model=\(model.rawValue) skipped=not_installed")
                continue
            }
            settings.parakeetModelChoice = model
            settings.selectedLanguage = .english
            settings.transcriptPostProcessingMode = .none
            let loadStart = ContinuousClock.now
            try await engine.prepare()
            print("REPRO_ASR_BENCHMARK model=\(model.rawValue) model_load_ms=\(BenchmarkStatistics.elapsedMilliseconds(from: loadStart))")
            try await benchmark(
                engine: engine,
                name: "parakeet",
                model: model.rawValue,
                audioURL: audioURL,
                audioSeconds: audioSeconds,
                iterations: iterations
            )
            didRun = true
        }

        if AppleSpeechEngine.isSupported {
            PerfTrace.clearSessionMetadata()
            let engine = AppleSpeechEngine()
            settings.appleSpeechLanguage = .english
            let installed = await AppleSpeechEngine.installedLanguages()
            if installed.contains(.english) { try await engine.prepare() }
            if engine.isReady {
                try await benchmark(
                    engine: engine,
                    name: "appleSpeech",
                    model: "english",
                    audioURL: audioURL,
                    audioSeconds: audioSeconds,
                    iterations: iterations
                )
                didRun = true
            }
        }

        try XCTSkipUnless(didRun, "No selected offline ASR model or installed Apple Speech asset is available")

        #endif
    }

    /// Uses four existing TTS fixtures with known references. Only runs when
    /// SenseVoice is already installed; the benchmark never downloads models.
    func testInstalledMandarinASRBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable Mandarin ASR benchmark")
        #else
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: .senseVoice), "SenseVoice is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            PerfTrace.clearSessionMetadata()
        }
        settings.parakeetModelChoice = .senseVoice
        settings.selectedLanguage = .chinese
        try await engine.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mandarin-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)

        for (fixture, reference) in MandarinFixtureTests.references.sorted(by: { $0.key < $1.key }) {
            let capture = try store.beginCapture()
            capture.append(try fixtureSamples(named: fixture))
            let saved = try await store.preserve(capture, preview: "", completedTranscript: nil)
            let entry = try XCTUnwrap(saved)
            let url = store.audioURL(id: entry.id)
            var latencies: [Double] = []
            var worstCER = 0.0
            for iteration in 1...max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3) {
                PerfTrace.setSessionMetadata([
                    "session_id": "benchmark-\(fixture)-\(iteration)", "engine": "parakeet",
                    "model": "senseVoice", "language": "chinese", "benchmark": "offline_asr"
                ])
                let start = ContinuousClock.now
                let text = try await engine.transcribeRecording(at: url)
                latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
                worstCER = max(worstCER, characterErrorRate(reference: reference, hypothesis: text))
            }
            BenchmarkStatistics(latencies).report(
                component: "mandarin_asr", details: "fixture=\(fixture) worst_cer=\(String(format: "%.3f", worstCER))"
            )
            XCTAssertLessThanOrEqual(worstCER, fixture == "zh-mixed" ? 0.5 : 0.3)
            try store.remove(id: entry.id)
        }
        #endif
    }

    /// An opt-in human-speech fixture can be passed without bundling or
    /// uploading its contents. Both audio and its exact reference are required.
    func testUserSuppliedSpeechFixtureBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable speech fixture benchmark")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["PIPELINE_BENCHMARK_AUDIO_PATH"],
              let referencePath = environment["PIPELINE_BENCHMARK_REFERENCE_PATH"] else {
            throw XCTSkip("Set PIPELINE_BENCHMARK_AUDIO_PATH and PIPELINE_BENCHMARK_REFERENCE_PATH")
        }
        let url = URL(fileURLWithPath: audioPath)
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let reader = try RecoveryAudioReader(url: url)
        try XCTSkipUnless(reader.nextSamples() != nil && !reference.isEmpty, "Empty fixture or reference")
        let modelName = environment["PIPELINE_BENCHMARK_MODEL"] ?? "parakeetEou320"
        let model = try XCTUnwrap(ParakeetModelChoice(rawValue: modelName), "Select one model for a supplied fixture")
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: model), "Selected speech model is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            PerfTrace.clearSessionMetadata()
        }
        settings.parakeetModelChoice = model
        settings.selectedLanguage = .english
        try await engine.prepare()
        let count = max(1, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        var latencies: [Double] = []
        var worstWER = 0.0
        for iteration in 1...count {
            PerfTrace.setSessionMetadata([
                "session_id": "benchmark-user-\(iteration)", "engine": "parakeet",
                "model": model.rawValue, "language": "english", "benchmark": "offline_asr"
            ])
            let start = ContinuousClock.now
            let text = try await engine.transcribeRecording(at: url)
            latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
            worstWER = max(worstWER, benchmarkWordErrorRate(reference: reference, hypothesis: text))
        }
        BenchmarkStatistics(latencies).report(
            component: "user_speech_asr", details: "model=\(model.rawValue) worst_wer=\(String(format: "%.3f", worstWER))"
        )
        if let threshold = environment["PIPELINE_BENCHMARK_MAX_WER"].flatMap(Double.init) {
            XCTAssertLessThanOrEqual(worstWER, threshold)
        }
        #endif
    }

    func testNonStreamingPendingAudioWorkBenchmark() throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable pipeline benchmarks")
        #else
        // Deterministic audio-time workload, including the authoritative SDK
        // overlap windows. This measures scheduling, not CPU time or WER.
        let rate = BatchTranscriptionPolicy.sampleRate
        let callbackSamples = rate / 2
        var lastPreview = 0
        var previews = 0
        var previewSamples = 0
        var overlapSamples = 0
        var nextWindow = 13 * rate
        for total in stride(from: callbackSamples, through: 60 * rate, by: callbackSamples) {
            if total >= nextWindow {
                overlapSamples += nextWindow == 13 * rate ? 13 * rate : 15 * rate
                nextWindow += 11 * rate
            }
            if BatchTranscriptionPolicy.shouldPreview(totalSamples: total, lastPreviewSamples: lastPreview, hasVisibleText: lastPreview > 0) {
                previewSamples += min(total, BatchTranscriptionPolicy.previewWindowSamples)
                lastPreview = total
                previews += 1
            }
        }
        // End-aligned SDK final flush: 11 s center plus 2 s left context.
        overlapSamples += 13 * rate
        let processed = previewSamples + overlapSamples
        XCTAssertEqual(previews, 60)
        XCTAssertLessThan(processed, 31_840_000, "Must beat the parent preview workload including overlap processing")
        print("PIPELINE_BENCHMARK component=model_aware_batch previews=\(previews) processed_samples=\(processed) parent_preview_samples=31840000")
        #endif
    }

    /// Paired comparison against the parent live policy. Replays identical
    /// audio through production capture-buffer iteration and Stop, with no mic.
    func testModelAwareBatchComparisonBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark with a referenced speech fixture")
        #else
        let environment = ProcessInfo.processInfo.environment
        let modelName = environment["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"
        try XCTSkipUnless(modelName != "all", "Select one model for the paired policy comparison")
        let choice = try XCTUnwrap(ParakeetModelChoice(rawValue: modelName), "Unknown benchmark model")
        try XCTSkipUnless(!choice.usesTrueStreaming, "Native streaming policy is unchanged")
        let inputFixture = try benchmarkFixture(model: choice)
        let engine = ParakeetEngine()
        try XCTSkipUnless(hasInstalledBenchmarkModel(choice, engine: engine), "Selected model or required VAD is not installed")
        let reader = try RecoveryAudioReader(url: inputFixture.url)
        var audio: [Float] = []
        while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
        let reference = inputFixture.reference
        try XCTSkipUnless(!audio.isEmpty && !reference.isEmpty, "Empty fixture or reference")
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldVocabulary = settings.transcriptPostProcessingMode
        defer { settings.parakeetModelChoice = oldChoice; settings.transcriptPostProcessingMode = oldVocabulary }
        settings.parakeetModelChoice = choice
        settings.transcriptPostProcessingMode = .none
        try await engine.prepare()
        let baseline: AsrManager?
        let senseVoice: SenseVoiceManager?
        if choice == .senseVoice {
            let models = try SenseVoiceModels.load(from: benchmarkModelRoot.appendingPathComponent(Repo.senseVoiceSmall.folderName), precision: ParakeetEngine.senseVoiceEncoderPrecision)
            senseVoice = SenseVoiceManager(models: models, language: SenseVoiceConfig.defaultLanguage, textNorm: 14)
            baseline = nil
        } else {
            let version: AsrModelVersion = choice == .multilingual ? .v3 : choice == .multilingualUltra ? .ultra : choice == .englishOnly ? .v2 : .tdtCtc110m
            let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
            try await manager.loadModels(models)
            baseline = manager
            senseVoice = nil
        }
        func decode(_ samples: [Float]) async throws -> String {
            if let senseVoice { return try await senseVoice.transcribe(audio: samples) }
            let baseline = try XCTUnwrap(baseline)
            var state = TdtDecoderState.make(decoderLayers: await baseline.decoderLayerCount)
            return try await baseline.transcribe(samples, decoderState: &state).text
        }
        _ = try await decode(Array(audio.prefix(16_000)))
        let iterations = max(1, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        var parentTimes: [Double] = [], candidateTimes: [Double] = []
        var parentFinishTimes: [Double] = [], candidateFinishTimes: [Double] = []
        var parentErrors: [Double] = [], candidateErrors: [Double] = []
        var firstVisibleAudioMilliseconds: [Double] = []
        var parentTranscripts: [String] = [], candidateTranscripts: [String] = []
        for iteration in 0..<iterations {
            // Shift seams relative to real speech without changing the reference.
            let input = [Float](repeating: 0, count: iteration * 8_000) + audio
            func parentRun() async throws {
                let began = ContinuousClock.now
                var pending: [Float] = [], committed = "", live = ""
                for offset in stride(from: 0, to: input.count, by: 8_000) {
                    let chunk = Array(input[offset..<min(offset + 8_000, input.count)])
                    pending.append(contentsOf: chunk)
                    while pending.count >= 30 * 16_000 {
                        let text = try await decode(Array(pending.prefix(20 * 16_000)))
                        committed = ParakeetEngine.joinChunkTranscripts(base: committed, addition: text)
                        pending.removeFirst(20 * 16_000)
                    }
                    if chunk.count > 4_800, engine.batchReplayHasSignificantAudioForTesting(Array(pending.suffix(8_000))) {
                        live = ParakeetEngine.joinChunkTranscripts(base: committed, addition: try await decode(pending))
                    }
                }
                let finishing = ContinuousClock.now
                while pending.count >= 20 * 16_000 {
                    committed = ParakeetEngine.joinChunkTranscripts(base: committed, addition: try await decode(Array(pending.prefix(20 * 16_000))))
                    pending.removeFirst(20 * 16_000)
                }
                if pending.count > 8_000, engine.batchReplayContainsSignificantAudioForTesting(pending) {
                    committed = ParakeetEngine.joinChunkTranscripts(base: committed, addition: try await decode(pending))
                }
                let final = committed.count >= live.count ? committed : live
                parentFinishTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: finishing))
                parentTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: began))
                parentErrors.append(GoldenSpeechFixture.errorRate(reference: reference, hypothesis: final, metric: inputFixture.metric))
                parentTranscripts.append(final)
            }
            func candidateRun() async throws {
                let began = ContinuousClock.now
                try await engine.beginBatchReplayForTesting()
                var firstVisible: Double?
                for offset in stride(from: 0, to: input.count, by: 8_000) {
                    try await engine.replayBatchAudioForTesting(Array(input[offset..<min(offset + 8_000, input.count)]))
                    if firstVisible == nil && !engine.currentTranscript.isEmpty {
                        firstVisible = Double(min(offset + 8_000, input.count)) / 16
                    }
                }
                let finishing = ContinuousClock.now
                let final = await engine.stopRecording()
                candidateFinishTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: finishing))
                candidateTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: began))
                candidateErrors.append(GoldenSpeechFixture.errorRate(reference: reference, hypothesis: final, metric: inputFixture.metric))
                candidateTranscripts.append(final)
                firstVisibleAudioMilliseconds.append(firstVisible ?? .infinity)
            }
            // Alternate order to reduce a consistent warm-cache advantage.
            if iteration.isMultiple(of: 2) { try await parentRun(); try await candidateRun() }
            else { try await candidateRun(); try await parentRun() }
            // Public, licensed goldens may expose a failed seam for diagnosis.
            // External recordings never have their text printed by this harness.
            if inputFixture.id != "external", candidateErrors[iteration] > parentErrors[iteration] {
                print("MODEL_POLICY_REGRESSION fixture=\(inputFixture.id) iteration=\(iteration) parent=\(parentTranscripts[iteration])")
                print("MODEL_POLICY_REGRESSION fixture=\(inputFixture.id) iteration=\(iteration) candidate=\(candidateTranscripts[iteration])")
            }
        }
        await baseline?.cleanup()
        let parentMean = parentTimes.reduce(0,+) / Double(iterations)
        let candidateMean = candidateTimes.reduce(0,+) / Double(iterations)
        let parentError = parentErrors.reduce(0,+) / Double(iterations)
        let candidateError = candidateErrors.reduce(0,+) / Double(iterations)
        print("MODEL_POLICY_BENCHMARK model=\(choice.rawValue) fixture=\(inputFixture.id) metric=\(inputFixture.metric.rawValue) iterations=\(iterations) parent_total_ms=\(parentTimes) candidate_total_ms=\(candidateTimes) parent_finish_ms=\(parentFinishTimes) candidate_finish_ms=\(candidateFinishTimes) parent_error=\(parentErrors) candidate_error=\(candidateErrors) candidate_first_visible_audio_ms=\(firstVisibleAudioMilliseconds)")
        XCTAssertLessThanOrEqual(candidateMean, parentMean, "Total recognition work regressed")
        XCTAssertLessThanOrEqual(candidateError, parentError, "Paired aggregate fixture quality regressed")
        #endif
    }

    /// Isolates the SDK's encoder placement recommendation from preview policy.
    /// Report both timings and exact golden-reference errors before adopting it.
    func testTDTEncoderPlacementBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run the encoder benchmark through scripts/dev.sh benchmark")
        #else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PIPELINE_BENCHMARK_ENCODER"] == "1", "Opt in to encoder placement comparison")
        let choice = try XCTUnwrap(ParakeetModelChoice(rawValue: environment["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"))
        try XCTSkipUnless(choice == .multilingual || choice == .multilingualUltra, "Encoder guidance applies to v3-family models")
        let version: AsrModelVersion = choice == .multilingual ? .v3 : .ultra
        var fixtures = try GoldenSpeechFixture.all().filter { $0.supports(choice) }
        if let id = environment["PIPELINE_BENCHMARK_FIXTURE"] { fixtures = fixtures.filter { $0.id == id } }
        let iterations = max(1, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        let ane = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
        let gpu = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
        try await ane.loadModels(AsrModels.loadFromCache(version: version, encoderComputeUnits: .cpuAndNeuralEngine))
        try await gpu.loadModels(AsrModels.loadFromCache(version: version, encoderComputeUnits: .cpuAndGPU))
        for fixture in fixtures {
            let reader = try RecoveryAudioReader(url: fixture.audioURL)
            var audio: [Float] = []
            while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
            var aneTimes: [Double] = [], gpuTimes: [Double] = []
            var aneErrors: [Double] = [], gpuErrors: [Double] = []
            for iteration in 0..<iterations {
                for useGPU in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let manager = useGPU ? gpu : ane
                    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    let start = ContinuousClock.now
                    let result = try await manager.transcribe(audio, decoderState: &state)
                    let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let error = try fixture.errorRate(hypothesis: result.text)
                    if useGPU { gpuTimes.append(elapsed); gpuErrors.append(error) }
                    else { aneTimes.append(elapsed); aneErrors.append(error) }
                }
            }
            print("ENCODER_BENCHMARK model=\(choice.rawValue) fixture=\(fixture.id) ane_ms=\(aneTimes) gpu_ms=\(gpuTimes) ane_error=\(aneErrors) gpu_error=\(gpuErrors)")
            XCTAssertEqual(gpuErrors, aneErrors, "Encoder placement changed golden accuracy")
        }
        await ane.cleanup()
        await gpu.cleanup()
        #endif
    }

    /// Human quality references run through the existing harness. Batch models
    /// use the live production iteration/Stop path; native models use recovery.
    func testGoldenSpeechReferenceBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark with PIPELINE_BENCHMARK_GOLDEN=1")
        #else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PIPELINE_BENCHMARK_GOLDEN"] == "1" || environment["PIPELINE_BENCHMARK_FIXTURE"] != nil,
                          "Opt in to bundled human references")
        let modelName = environment["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"
        let models = modelName == "all" ? ParakeetModelChoice.allCases : [try XCTUnwrap(ParakeetModelChoice(rawValue: modelName))]
        var fixtures = try GoldenSpeechFixture.all()
        if let id = environment["PIPELINE_BENCHMARK_FIXTURE"] {
            fixtures = [try XCTUnwrap(fixtures.first { $0.id == id }, "Unknown golden fixture: \(id)")]
        }
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        let oldLanguage = settings.selectedLanguage
        defer { settings.parakeetModelChoice = oldChoice; settings.transcriptPostProcessingMode = oldMode; settings.selectedLanguage = oldLanguage }
        settings.transcriptPostProcessingMode = .none
        let iterations = max(1, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        var ran = 0
        for model in models {
            let engine = ParakeetEngine()
            guard model.isAvailableOnThisMac, hasInstalledBenchmarkModel(model, engine: engine) else { continue }
            let supported = fixtures.filter { $0.supports(model) }
            guard !supported.isEmpty else { continue }
            settings.parakeetModelChoice = model
            try await engine.prepare()
            for fixture in supported {
                settings.selectedLanguage = SupportedLanguage(rawValue: fixture.language) ?? .chinese
                let reader = try RecoveryAudioReader(url: fixture.audioURL)
                var audio: [Float] = []
                while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
                var latencies: [Double] = [], errors: [Double] = []
                for _ in 0..<iterations {
                    let began = ContinuousClock.now
                    let text: String
                    if model.usesTrueStreaming {
                        text = try await engine.transcribeRecording(at: fixture.audioURL)
                    } else {
                        try await engine.beginBatchReplayForTesting()
                        for offset in stride(from: 0, to: audio.count, by: 8_000) {
                            try await engine.replayBatchAudioForTesting(Array(audio[offset..<min(offset + 8_000, audio.count)]))
                        }
                        text = await engine.stopRecording()
                    }
                    latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: began))
                    errors.append(try fixture.errorRate(hypothesis: text))
                    XCTAssertFalse(text.isEmpty, "\(model.rawValue) \(fixture.id) returned empty text")
                }
                BenchmarkStatistics(latencies).report(component: "golden_speech", details:
                    "model=\(model.rawValue) fixture=\(fixture.id) path=\(model.usesTrueStreaming ? "recovery" : "live_replay") metric=\(fixture.metric.rawValue) error=\(errors)")
                ran += 1
            }
        }
        try XCTSkipUnless(ran > 0, "No installed model supports the selected golden fixtures")
        #endif
    }

    private func benchmarkFixture(model: ParakeetModelChoice) throws -> (url: URL, reference: String, metric: GoldenSpeechFixture.Metric, id: String) {
        let environment = ProcessInfo.processInfo.environment
        if let id = environment["PIPELINE_BENCHMARK_FIXTURE"] {
            let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == id }, "Unknown golden fixture: \(id)")
            try XCTSkipUnless(fixture.supports(model), "Selected model does not support \(fixture.language)")
            return (try fixture.audioURL, try fixture.referenceText, fixture.metric, fixture.id)
        }
        guard let path = environment["PIPELINE_BENCHMARK_AUDIO_PATH"],
              let referencePath = environment["PIPELINE_BENCHMARK_REFERENCE_PATH"] else {
            throw XCTSkip("Set PIPELINE_BENCHMARK_FIXTURE or both external audio/reference paths")
        }
        let metric = try XCTUnwrap(GoldenSpeechFixture.Metric(rawValue: environment["PIPELINE_BENCHMARK_METRIC"] ?? "wer"), "Metric must be wer or cer")
        return (URL(fileURLWithPath: path), try String(contentsOfFile: referencePath, encoding: .utf8), metric, "external")
    }

    private var benchmarkModelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private func hasInstalledBenchmarkModel(_ model: ParakeetModelChoice, engine: ParakeetEngine) -> Bool {
        guard engine.checkModelOnDisk(for: model) else { return false }
        guard !model.usesTrueStreaming else { return true }
        let hasVad = FileManager.default.fileExists(atPath: benchmarkModelRoot
                .appendingPathComponent(Repo.vad.folderName)
                .appendingPathComponent(ModelNames.VAD.sileroVadFile).path)
        guard model == .senseVoice else { return hasVad }
        return hasVad && SenseVoiceModels.modelsExist(at: benchmarkModelRoot.appendingPathComponent(Repo.senseVoiceSmall.folderName), precision: ParakeetEngine.senseVoiceEncoderPrecision)
    }

    private func benchmark(
        engine: TranscriptionEngine,
        name: String,
        model: String,
        audioURL: URL,
        audioSeconds: Double,
        iterations: Int
    ) async throws {
        var latencies: [Double] = []
        for iteration in 1...iterations {
            PerfTrace.setSessionMetadata([
                "session_id": "benchmark-\(name)-\(iteration)",
                "benchmark": "offline_asr",
                "iteration": String(iteration),
                "engine": name,
                "model": model,
                "language": "english",
                "cleanup_mode": "none",
                "s1_mini_enabled": "false",
                "filler_removal_enabled": "false",
                "context_awareness_enabled": "false"
            ])
            let startedAt = ContinuousClock.now
            let text = try await engine.transcribeRecording(at: audioURL)
            let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: startedAt)
            latencies.append(elapsed)
            XCTAssertFalse(text.isEmpty, "\(name) benchmark produced no transcript")
            XCTAssertTrue(text.localizedCaseInsensitiveContains("weather"), "\(name) lost the fixture beginning")
            XCTAssertTrue(text.localizedCaseInsensitiveContains("cancellation"), "\(name) lost the fixture ending")
            print("REPRO_ASR_BENCHMARK engine=\(name) model=\(model) iteration=\(iteration) elapsed_ms=\(elapsed)")
        }
        BenchmarkStatistics(latencies).report(
            component: "offline_asr",
            details: "engine=\(name) model=\(model) audio_seconds=\(String(format: "%.3f", audioSeconds)) "
                + "median_rtf=\(String(format: "%.3f", BenchmarkStatistics(latencies).p50 / 1_000 / audioSeconds))"
        )
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

    private func fixtureSamples(named name: String = "en-recovery") throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
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

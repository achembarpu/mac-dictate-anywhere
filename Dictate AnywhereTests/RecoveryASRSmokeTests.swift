#if PIPELINE_BENCHMARK
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

    func testInstalledModelsPrepareOnceAndRecoverWithoutWarmupText() async throws {
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldChoice
            settings.transcriptPostProcessingMode = oldMode
            settings.selectedLanguage = oldLanguage
            #if DEBUG
            PerfTrace.onIntervalCompleted = nil
            #endif
        }
        settings.transcriptPostProcessingMode = .none
        let name = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_MODEL"] ?? "all"
        let models = name == "all" ? ParakeetModelChoice.availableCases : [try XCTUnwrap(ParakeetModelChoice(rawValue: name))]
        var ran = 0
        for model in models where model.isAvailableOnThisMac {
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
            settings.selectedLanguage = SupportedLanguage(rawValue: fixture.language) ?? .english
            let output = try await engine.transcribeRecording(at: fixture.audioURL)
            XCTAssertFalse(output.isEmpty, model.rawValue)
            XCTAssertLessThan(try fixture.errorRate(hypothesis: output), 0.5, "Warmup contaminated \(model.rawValue): \(output)")
            if [.englishOnly, .parakeetEou320, .multilingual, .nemotron1120].contains(model) {
                settings.selectedLanguage = .english
                try await checkRecovery(using: engine)
            }
            await engine.cancel()
            ran += 1
        }
        try XCTSkipUnless(ran > 0, "No selected model is installed")
    }

    /// Explicit opt-in only. Uses the app's downloader and its persistent cache,
    /// so installed artifacts are immediately reusable by normal app sessions.
    func testDownloadModelsIntoApplicationCache() async throws {
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
        #if DEBUG
        let lateLoads = OSAllocatedUnfairLock(initialState: 0)
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "stt.ctcModelLoad" || name == "stt.ctcWarmup" { lateLoads.withLock { $0 += 1 } }
        }
        defer { PerfTrace.onIntervalCompleted = nil }
        #endif
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
        #if DEBUG
        XCTAssertEqual(lateLoads.withLock { $0 }, 0, "CTC weights loaded at Stop instead of during preparation")
        #endif
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
        let radiansPerSample = 2.0 * Double.pi * 120.0 / 16_000.0
        let tone: [Float] = (0..<32_000).map { index in
            Float(sin(Double(index) * radiansPerSample)) * Float(0.003)
        }
        try await engine.beginBatchReplayForTesting()
        for offset in stride(from: 0, to: tone.count, by: 8_000) {
            try await engine.replayBatchAudioForTesting(Array(tone[offset..<offset + 8_000]))
        }
        let noise = await engine.stopRecording()
        XCTAssertEqual(noise, "")
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

    /// An opt-in human-speech fixture can be passed without bundling or
    /// uploading its contents. Both audio and its exact reference are required.
    func testUserSuppliedSpeechFixtureBenchmark() async throws {
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
    }

    func testCancelledBatchReplayKeepsFinalAudioWithoutStartingAPreview() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark with an installed batch model")
        #else
        let name = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_MODEL"] ?? "englishOnly"
        let choice = try XCTUnwrap(ParakeetModelChoice(rawValue: name))
        try XCTSkipUnless(!choice.usesTrueStreaming, "Select a batch model")
        let id = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_FIXTURE"] ?? "golden-en-1"
        let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == id }, "Unknown golden fixture: \(id)")
        try XCTSkipUnless(fixture.supports(choice), "Selected model does not support \(fixture.language)")
        let engine = ParakeetEngine()
        try XCTSkipUnless(hasInstalledBenchmarkModel(choice, engine: engine), "Install selected model and VAD")
        let reader = try RecoveryAudioReader(url: fixture.audioURL)
        var audio: [Float] = []
        while let block = try reader.nextSamples() { audio.append(contentsOf: block) }
        let settings = Settings.shared
        let oldChoice = settings.parakeetModelChoice
        let oldMode = settings.transcriptPostProcessingMode
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldChoice
            settings.transcriptPostProcessingMode = oldMode
            settings.selectedLanguage = oldLanguage
        }
        settings.parakeetModelChoice = choice
        settings.transcriptPostProcessingMode = .none
        settings.selectedLanguage = SupportedLanguage(rawValue: fixture.language) ?? .english
        try await engine.prepare()
        try await engine.beginBatchReplayForTesting()
        // Main-actor scheduling makes cancellation precede this task's first
        // instruction. Audio must still reach the finalizer before checking it.
        let replay = Task { try await engine.replayBatchAudioForTesting(audio) }
        replay.cancel()
        do { try await replay.value; XCTFail("A cancelled replay must skip preview decoding") }
        catch is CancellationError {}
        XCTAssertTrue(engine.currentTranscript.isEmpty)
        XCTAssertEqual(engine.capturedSampleCountsForTesting.total, audio.count)
        let final = await engine.stopRecording()
        XCTAssertFalse(final.isEmpty, "Stopping preview work cannot discard captured audio")
        try await engine.beginBatchReplayForTesting()
        try await engine.replayBatchAudioForTesting(audio)
        let normal = await engine.stopRecording()
        let cancelledError = try fixture.errorRate(hypothesis: final)
        let normalError = try fixture.errorRate(hypothesis: normal)
        XCTAssertEqual(cancelledError, normalError, accuracy: 0.000_001,
            "Cancelled previews must leave authoritative final quality unchanged")
        print("CANCELLED_PREVIEW_RESULT model=\(choice.rawValue) fixture=\(fixture.id) error_rate=\(cancelledError) normal_error_rate=\(normalError)")
        #endif
    }

    /// Isolates the SDK's encoder placement recommendation from preview policy.
    /// Report both timings and exact golden-reference errors before adopting it.
    func testTDTEncoderPlacementBenchmark() async throws {
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
    }

    /// Human quality references run through the existing harness. Batch models
    /// use the live production iteration/Stop path; native models use recovery.
    func testGoldenSpeechReferenceBenchmark() async throws {
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
#endif

#if PIPELINE_BENCHMARK
import FluidAudio
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class TDTVocabularyBenchmarkTests: XCTestCase {
    func testAuxiliaryHeadInstallationAndRepair() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use tdt-vocabulary with explicit model downloads")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_DOWNLOAD_MODELS"] == "1",
                          "Set PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 to exercise downloads")
        let models = try await CompactSpeechModelLoader.load(download: false)
        // First ensure the head is usable in the actual application cache.
        let appHead = try await VocabularyHeadLoader.load(configuration: models.configuration)
        let appSession = try await SharedCTCVocabularySession.prepare(models: models, terms: ["Quilter"],
            config: VocabularyRescoringPolicy.config, cachedHead: appHead)
        try await appSession.warm()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-head-\(UUID())")
        let cold = root.appendingPathComponent("cold")
        let repair = root.appendingPathComponent("repair")
        let files = FileManager.default
        let offline = ModelHub.offlineMode
        defer { ModelHub.offlineMode = offline; try? files.removeItem(at: root) }
        let name = ModelNames.ASR.ctcHeadFile
        let head = try await VocabularyHeadLoader.load(configuration: models.configuration, directory: cold)
        let session = try await SharedCTCVocabularySession.prepare(models: models, terms: ["Quilter"],
            config: VocabularyRescoringPolicy.config, cachedHead: head)
        try await session.warm()
        XCTAssertFalse(files.fileExists(atPath: cold.appendingPathComponent("AudioEncoder.mlmodelc").path))
        let original = try Data(contentsOf: cold.appendingPathComponent(name).appendingPathComponent("coremldata.bin"))
        ModelHub.offlineMode = true
        _ = try await VocabularyHeadLoader.load(configuration: models.configuration, directory: cold)
        do {
            _ = try await VocabularyHeadLoader.load(configuration: models.configuration, directory: root.appendingPathComponent("missing"))
            XCTFail("Missing assets must not report successful preparation offline")
        } catch { XCTAssertTrue(ModelHub.offlineMode) }
        ModelHub.offlineMode = false
        try files.createDirectory(at: repair, withIntermediateDirectories: true)
        try files.copyItem(at: cold.appendingPathComponent(name), to: repair.appendingPathComponent(name))
        try Data("invalid Core ML model".utf8).write(to: repair.appendingPathComponent(name).appendingPathComponent("coremldata.bin"))
        let repaired = try await VocabularyHeadLoader.load(configuration: models.configuration, directory: repair)
        XCTAssertEqual(try Data(contentsOf: repair.appendingPathComponent(name).appendingPathComponent("coremldata.bin")), original)
        let repairedSession = try await SharedCTCVocabularySession.prepare(models: models, terms: ["Quilter"],
            config: VocabularyRescoringPolicy.config, cachedHead: repaired)
        try await repairedSession.warm()
        XCTAssertFalse(files.fileExists(atPath: repair.appendingPathComponent("AudioEncoder.mlmodelc").path))
        print("VOCABULARY_HEAD_INSTALLATION_RESULT app_cache_ready=true cold_download=true offline_reuse=true corrupt_load_repaired=true extra_encoder=false")
        #endif
    }

    func testPreparedVocabularyProductionSessions() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use --only tdt-vocabulary for prepared production sessions")
        #else
        let settings = Settings.shared
        let saved = (settings.parakeetModelChoice, settings.transcriptPostProcessingMode, settings.customVocabulary)
        defer {
            settings.parakeetModelChoice = saved.0; settings.transcriptPostProcessingMode = saved.1
            settings.customVocabulary = saved.2
        }
        settings.parakeetModelChoice = .compactEnglish
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.customVocabulary = ["Chandra Shekhar Solanki"]
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: .compactEnglish), "Install 110M first")
        try await engine.prepare()
        let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == "golden-en-fleurs-2" })
        for iteration in 0..<3 {
            settings.customVocabulary = ["Chandra Shekhar Solanki"]
            let preparation = ContinuousClock.now
            let ready = await engine.prepareVocabularyIfNeeded()
            XCTAssertTrue(ready)
            XCTAssertEqual(engine.vocabularyReadiness, .ready)
            let preparationMs = BenchmarkStatistics.elapsedMilliseconds(from: preparation)
            try await engine.beginBatchReplayForTesting()
            let reader = try RecoveryAudioReader(url: fixture.audioURL)
            while let chunk = try reader.nextSamples(maxSamples: 16_000) { try await engine.replayBatchAudioForTesting(chunk) }
            // An edit during capture applies to the next recording only.
            settings.customVocabulary = ["cancellation"]
            XCTAssertFalse(engine.vocabularyReadiness.isReady, "New terms must not inherit old readiness")
            let before = try BenchmarkProcessResources.sample()
            let start = ContinuousClock.now
            let output = await engine.stopRecording()
            let stopMs = BenchmarkStatistics.elapsedMilliseconds(from: start)
            XCTAssertTrue(output.localizedCaseInsensitiveContains("Chandra Shekhar Solanki"), output)
            XCTAssertFalse(output.localizedCaseInsensitiveContains("cancellation"))
            try emit(fixture: fixture, model: .compactEnglish, list: "recording_snapshot",
                terms: ["Chandra Shekhar Solanki"], variant: "prepared_live", iteration: iteration,
                elapsed: stopMs, cpu: try BenchmarkProcessResources.sample().cpuMilliseconds - before.cpuMilliseconds,
                peak: try BenchmarkProcessResources.sample().peakResidentBytes,
                original: "", output: output, error: fixture.errorRate(hypothesis: output), preparation: preparationMs)
        }
        settings.parakeetModelChoice = .senseVoice
        await engine.handleSelectedModelChange()
        settings.parakeetModelChoice = .compactEnglish
        await engine.handleSelectedModelChange()
        XCTAssertFalse(engine.vocabularyReadiness.isReady, "Unloaded components must be prepared again")
        settings.transcriptPostProcessingMode = .none
        XCTAssertEqual(engine.vocabularyReadiness, .needsSetup)
        await engine.cancel()
        #endif
    }

    func testVocabularyPreviewAvoidsDiscardedOverlapDecoder() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use tdt-vocabulary for production preview/finalization checks")
        #else
        let settings = Settings.shared
        let saved = (settings.parakeetModelChoice, settings.transcriptPostProcessingMode,
                     settings.customVocabulary, settings.selectedLanguage)
        defer {
            settings.parakeetModelChoice = saved.0; settings.transcriptPostProcessingMode = saved.1
            settings.customVocabulary = saved.2; settings.selectedLanguage = saved.3
        }
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.selectedLanguage = .english
        let fixture = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == "golden-en-fleurs-2" })
        let reader = try RecoveryAudioReader(url: fixture.audioURL)
        var audio: [Float] = []
        while let chunk = try reader.nextSamples() { audio.append(contentsOf: chunk) }
        let terms = ["Chandra Shekhar Solanki"]
        let versions: [(ParakeetModelChoice, AsrModelVersion)] = [
            (.multilingual, .v3), (.multilingualUltra, .ultra), (.englishOnly, .v2), (.compactEnglish, .tdtCtc110m)
        ]
        let requested = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_MODEL"] ?? "all"
        var ran = 0
        for (choice, version) in versions where requested == "all" || requested == choice.rawValue {
            let engine = ParakeetEngine()
            guard engine.checkModelOnDisk(for: choice) else { continue }
            settings.parakeetModelChoice = choice
            settings.customVocabulary = terms
            try await engine.prepare()
            try await engine.beginBatchReplayForTesting()
            let overlap = await engine.batchReplayUsesOverlapDecoderForTesting()
            XCTAssertFalse(overlap, "Vocabulary finalization must not start discarded overlap work")
            let start = ContinuousClock.now
            for offset in stride(from: 0, to: audio.count, by: 8_000) {
                try await engine.replayBatchAudioForTesting(Array(audio[offset..<min(offset + 8_000, audio.count)]))
            }
            XCTAssertFalse(engine.currentTranscript.isEmpty, "Batch-only previews must stay visible")
            let output = await engine.stopRecording()
            let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
            XCTAssertEqual(engine.capturedSampleCountsForTesting.retained, 0, "Stop releases retained PCM")
            // The same accurate whole-recording decoder/CTC path is the reference.
            let models = try await AsrModels.loadFromCache(version: version)
            let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
            try await manager.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let original = try await manager.transcribe(audio, decoderState: &state,
                language: BatchTranscriptionPolicy.scriptLanguage(for: choice, selected: .english))
            let vocabulary = try await PreparedTDTVocabulary.prepare(models: models, terms: terms, cachedCTCModels: nil)
            let expected = try await vocabulary.rescore(original, samples: audio)
            XCTAssertEqual(output, expected.trimmingCharacters(in: .whitespacesAndNewlines))
            BenchmarkStatistics([elapsed]).report(component: "vocabulary_live_without_overlap",
                details: "model=\(choice.rawValue) fixture=\(fixture.id) error=\(try fixture.errorRate(hypothesis: output))")
            await manager.cleanup()
            settings.customVocabulary = []
            try await engine.beginBatchReplayForTesting()
            let ordinaryOverlap = await engine.batchReplayUsesOverlapDecoderForTesting()
            XCTAssertEqual(ordinaryOverlap, choice != .englishOnly)
            await engine.cancel()
            ran += 1
        }
        try XCTSkipUnless(ran > 0, "Install a selected TDT model and vocabulary assets")
        #endif
    }

    func testVocabularyPoliciesAndSharedHead() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use --only tdt-vocabulary for paired installed-model vocabulary checks")
        #else
        let env = ProcessInfo.processInfo.environment
        let selected = env["PIPELINE_BENCHMARK_MODEL"] ?? "compactEnglish"
        let models: [ParakeetModelChoice] = selected == "all"
            ? [.multilingual, .multilingualUltra, .englishOnly, .compactEnglish]
            : [try XCTUnwrap(ParakeetModelChoice(rawValue: selected))]
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "2") ?? 2))
        let all = try GoldenSpeechFixture.all()
        let ids = (env["PIPELINE_BENCHMARK_FIXTURE"] ?? "golden-en-1,golden-en-fleurs-2,golden-en-ami-3,golden-en-ami-2,golden-en-fleurs-1,golden-en-boundaries").split(separator: ",").map(String.init)
        let fixtures = try ids.map { id in try XCTUnwrap(all.first { $0.id == id }) }
        let ctcDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        try XCTSkipUnless(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "tokenizer.json"].allSatisfy {
            FileManager.default.fileExists(atPath: ctcDirectory.appendingPathComponent($0).path)
        }, "Install CTC vocabulary assets first")
        let ctcModels = try await CtcModels.loadDirect(from: ctcDirectory)
        let oldConfig = VocabularyRescorer.Config(spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50)
        let strict = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, shortTermCbwTaperExponent: 2,
            spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50, spotterRescueEnabled: false)
        let genuine: [String: [String]] = ["golden-en-1": ["Quilter"],
            "golden-en-fleurs-2": ["Chandra Shekhar Solanki"], "golden-en-ami-3": ["David", "Andrew", "Craig"],
            "golden-en-boundaries": ["Quilter", "Gospel"]]
        for choice in models {
            let version: AsrModelVersion
            switch choice {
            case .multilingual: version = .v3
            case .multilingualUltra: version = .ultra
            case .englishOnly: version = .v2
            case .compactEnglish: version = .tdtCtc110m
            default: XCTFail("Select a TDT model"); return
            }
            guard ParakeetEngine().checkModelOnDisk(for: choice) else { continue }
            let models = try await AsrModels.loadFromCache(version: version)
            let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
            try await manager.loadModels(models)
            if choice == .compactEnglish {
                let shared = try await SharedCTCVocabularySession.prepare(models: models, terms: ["Quilter"], config: VocabularyRescoringPolicy.config)
                // The centered frontend includes the frame at the endpoint
                // when the sample count is an exact multiple of 80 ms.
                // Exercise both that boundary and overlapping window joins.
                for count in [1_279, 1_280, 1_281, 239_999, 240_000, 240_001, 414_720, 414_721] {
                    let grid = try await shared.logProbabilities(samples: [Float](repeating: 0, count: count))
                    XCTAssertEqual(grid.frameDuration, ASRConstants.secondsPerEncoderFrame)
                    XCTAssertEqual(grid.frames.count, count / ASRConstants.samplesPerEncoderFrame + 1,
                                   "Centered encoder grid for \(count) samples")
                }
            }
            for fixture in fixtures {
                let reader = try RecoveryAudioReader(url: fixture.audioURL)
                var samples: [Float] = []
                while let chunk = try reader.nextSamples(maxSamples: 16_000 * 20) { samples += chunk }
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let original = try await manager.transcribe(samples, decoderState: &state)
                if choice == .compactEnglish, fixture.id == "golden-en-fleurs-2" {
                    let withoutHead = AsrModels(encoder: models.encoder, preprocessor: models.preprocessor,
                        decoder: models.decoder, joint: models.joint, configuration: models.configuration,
                        vocabulary: models.vocabulary, version: models.version)
                    let fallback = try await PreparedTDTVocabulary.prepare(models: withoutHead,
                        terms: ["Chandra Shekhar Solanki"], cachedCTCModels: ctcModels)
                    guard case .shared = fallback else {
                        XCTFail("Missing SDK head must be loaded explicitly for the fast vocabulary path"); return
                    }
                    let output = try await fallback.rescore(original, samples: samples)
                    XCTAssertTrue(output.localizedCaseInsensitiveContains("Chandra Shekhar Solanki"), output)
                    XCTAssertLessThanOrEqual(try fixture.errorRate(hypothesis: output), try fixture.errorRate(hypothesis: original.text))
                }
                for (list, terms) in [("genuine", genuine[fixture.id] ?? ["Quilter"]),
                                      ("distractors", ["CRAN", "ran", "NVIDIA", "cancellation"])] {
                    var errors: [String: Double] = [:]
                    for (variant, config) in [("floors", oldConfig), ("taper", VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, shortTermCbwTaperExponent: 2,
                            spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50)), ("strict", strict)] {
                        let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(
                            terms: terms.map { CustomVocabularyTerm(text: $0) }), ctcModels: ctcModels, config: config)
                        for iteration in 0..<iterations {
                            let before = try BenchmarkProcessResources.sample()
                            let start = ContinuousClock.now
                            let rescored = await session.rescore(text: original.text, tokenTimings: original.tokenTimings ?? [], audioSamples: samples)
                            let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                            let after = try BenchmarkProcessResources.sample()
                            let output = rescored?.wasModified == true ? rescored!.text : original.text
                            let error = try fixture.errorRate(hypothesis: output)
                            errors[variant] = error
                            try emit(fixture: fixture, model: choice, list: list, terms: terms, variant: variant,
                                iteration: iteration, elapsed: elapsed, cpu: after.cpuMilliseconds - before.cpuMilliseconds,
                                peak: after.peakResidentBytes, original: original.text, output: output, error: error)
                        }
                    }
                    XCTAssertLessThanOrEqual(try XCTUnwrap(errors["strict"]), try XCTUnwrap(errors["floors"]),
                                             "Precision policy regressed \(choice.rawValue)/\(fixture.id)/\(list)")
                    if choice == .compactEnglish {
                        let shared = try await SharedCTCVocabularySession.prepare(models: models, terms: terms, config: VocabularyRescoringPolicy.config)
                        try await shared.warm()
                        let grid = try await shared.logProbabilities(samples: samples)
                        XCTAssertEqual(grid.frameDuration, ASRConstants.secondsPerEncoderFrame)
                        XCTAssertEqual(grid.frames.count, samples.count / ASRConstants.samplesPerEncoderFrame + 1,
                                       "The shared CTC clock must cover the complete recording")
                        for iteration in 0..<iterations {
                            let before = try BenchmarkProcessResources.sample()
                            let start = ContinuousClock.now
                            let output = try await shared.rescore(original, samples: samples)
                            let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                            let after = try BenchmarkProcessResources.sample()
                            let error = try fixture.errorRate(hypothesis: output)
                            try emit(fixture: fixture, model: choice, list: list, terms: terms, variant: "shared",
                                iteration: iteration, elapsed: elapsed, cpu: after.cpuMilliseconds - before.cpuMilliseconds,
                                peak: after.peakResidentBytes, original: original.text, output: output, error: error)
                            XCTAssertLessThanOrEqual(error, try XCTUnwrap(errors["strict"]), "Shared head regressed \(fixture.id)/\(list)")
                        }
                    }
                }
            }
            await manager.cleanup()
        }
        #endif
    }

    #if PIPELINE_BENCHMARK
    private func emit(fixture: GoldenSpeechFixture, model: ParakeetModelChoice, list: String, terms: [String],
                      variant: String, iteration: Int, elapsed: Double, cpu: Double, peak: Int64,
                      original: String, output: String, error: Double, preparation: Double? = nil) throws {
        let row: [String: Any] = ["experiment": "tdt_vocabulary", "model": model.rawValue, "fixture": fixture.id,
            "list": list, "terms": terms, "variant": variant, "iteration": iteration,
            "latency_ms": elapsed, "cpu_ms": cpu, "process_peak_rss_bytes": peak,
            "stage": variant == "prepared_live" ? "stop_to_final" : "rescore",
            "output": output, "error_rate": error,
            "audio_sha256": fixture.audioSHA256, "reference_sha256": fixture.referenceSHA256]
        var result = row
        if !original.isEmpty {
            result["original"] = original
            result["original_error_rate"] = try fixture.errorRate(hypothesis: original)
        }
        if let preparation { result["preparation_ms"] = preparation }
        print("MODEL_VOCABULARY_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    #endif
}

#endif

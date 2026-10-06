import FluidAudio
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class TDTVocabularyBenchmarkTests: XCTestCase {
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
            let preparationMs = BenchmarkStatistics.elapsedMilliseconds(from: preparation)
            try await engine.beginBatchReplayForTesting()
            let reader = try RecoveryAudioReader(url: fixture.audioURL)
            while let chunk = try reader.nextSamples(maxSamples: 16_000) { try await engine.replayBatchAudioForTesting(chunk) }
            // An edit during capture applies to the next recording only.
            settings.customVocabulary = ["cancellation"]
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
        await engine.cancel()
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
            for fixture in fixtures {
                let reader = try RecoveryAudioReader(url: fixture.audioURL)
                var samples: [Float] = []
                while let chunk = try reader.nextSamples(maxSamples: 16_000 * 20) { samples += chunk }
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let original = try await manager.transcribe(samples, decoderState: &state)
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
            "original": original, "output": output, "error_rate": error,
            "original_error_rate": try fixture.errorRate(hypothesis: original),
            "audio_sha256": fixture.audioSHA256, "reference_sha256": fixture.referenceSHA256]
        var result = row
        if let preparation { result["preparation_ms"] = preparation }
        print("MODEL_VOCABULARY_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    #endif
}

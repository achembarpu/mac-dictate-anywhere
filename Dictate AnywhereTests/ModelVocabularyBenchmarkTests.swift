import Foundation
import FluidAudio
import XCTest
@testable import Dictate_Anywhere

/// Paired production paths, with the same human references and resource scorer.
@MainActor
final class ModelVocabularyBenchmarkTests: XCTestCase {
    func testLanguageScriptFilteringOnFiles() async throws {
        try await compareScriptFiltering(live: false)
    }

    func testLanguageScriptFilteringOnLiveSessions() async throws {
        try await compareScriptFiltering(live: true)
    }

    private func compareScriptFiltering(live: Bool) async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use --only asr-language for paired installed-model checks")
        #else
        let env = ProcessInfo.processInfo.environment
        let selected = env["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"
        let models: [ParakeetModelChoice] = selected == "all" ? [.multilingual, .multilingualUltra]
            : [try XCTUnwrap(ParakeetModelChoice(rawValue: selected))]
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let fixtures = try selectedFixtures()
        let settings = Settings.shared
        let savedModel = settings.parakeetModelChoice
        let savedLanguage = settings.selectedLanguage
        let savedMode = settings.transcriptPostProcessingMode
        defer {
            settings.parakeetModelChoice = savedModel
            settings.selectedLanguage = savedLanguage
            settings.transcriptPostProcessingMode = savedMode
        }
        settings.transcriptPostProcessingMode = .none
        var ran = 0
        for model in models {
            guard model == .multilingual || model == .multilingualUltra else {
                XCTFail("Script filtering applies only to v3/Ultra"); return
            }
            let engine = ParakeetEngine()
            guard engine.checkModelOnDisk(for: model) else { continue }
            settings.parakeetModelChoice = model
            try await engine.prepare()
            for fixture in fixtures where fixture.supports(model) {
                settings.selectedLanguage = try XCTUnwrap(SupportedLanguage(rawValue: fixture.language))
                let samples = try readSamples(fixture)
                // Alternate order so backend/graph warmup does not favor the candidate.
                for iteration in 0..<iterations {
                    var errors: [Bool: Double] = [:]
                    for filtered in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                        engine.usesScriptFilterForTesting = filtered
                        let before = try BenchmarkProcessResources.sample()
                        let start = ContinuousClock.now
                        let output: String
                        if live {
                            try await engine.beginBatchReplayForTesting()
                            for offset in stride(from: 0, to: samples.count, by: 16_000) {
                                try await engine.replayBatchAudioForTesting(Array(samples[offset..<min(offset + 16_000, samples.count)]))
                            }
                            output = await engine.stopRecording()
                        } else { output = try await engine.transcribeRecording(at: fixture.audioURL) }
                        let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                        let after = try BenchmarkProcessResources.sample()
                        let error = try fixture.errorRate(hypothesis: output)
                        errors[filtered] = error
                        try emit(["experiment": "script", "model": model.rawValue,
                            "fixture": fixture.id, "language": fixture.language,
                            "filtered": filtered, "iteration": iteration,
                            "path": live ? "production_live" : "production_file",
                            "latency_ms": elapsed, "cpu_ms": after.cpuMilliseconds - before.cpuMilliseconds,
                            "process_peak_rss_bytes": after.peakResidentBytes,
                            "audio_sha256": fixture.audioSHA256, "reference_sha256": fixture.referenceSHA256,
                            "error_rate": error, "output": output])
                        XCTAssertFalse(output.isEmpty)
                        ran += 1
                    }
                    XCTAssertLessThanOrEqual(try XCTUnwrap(errors[true]), try XCTUnwrap(errors[false]),
                                             "Script hint regressed \(model.rawValue)/\(fixture.id)")
                }
            }
        }
        try XCTSkipUnless(ran > 0, "No selected model installed")
        #endif
    }

    #if PIPELINE_BENCHMARK
    private func selectedFixtures() throws -> [GoldenSpeechFixture] {
        let all = try GoldenSpeechFixture.all()
        guard let selection = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_FIXTURE"] else {
            return all.filter { !$0.tags.contains("derived-control") && ["en", "nl", "de"].contains($0.language) }
        }
        let ids = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard Set(ids).count == ids.count else { throw NSError(domain: "BenchmarkFixture", code: 1) }
        return try ids.map { id in try XCTUnwrap(all.first { $0.id == id }, "Unknown fixture: \(id)") }
    }

    private func readSamples(_ fixture: GoldenSpeechFixture) throws -> [Float] {
        let reader = try RecoveryAudioReader(url: fixture.audioURL)
        var samples: [Float] = []
        while let chunk = try reader.nextSamples(maxSamples: 16_000 * 20) { samples.append(contentsOf: chunk) }
        return samples
    }

    private func emit(_ row: [String: Any]) throws {
        print("MODEL_VOCABULARY_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
    #endif
}

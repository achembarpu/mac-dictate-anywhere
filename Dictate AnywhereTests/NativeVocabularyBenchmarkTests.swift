import Foundation
import FluidAudio
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class NativeVocabularyBenchmarkTests: XCTestCase {
    func testNativeVocabularyOnFiles() async throws { try await compareNativeVocabulary(live: false) }
    func testNativeVocabularyOnLiveSessions() async throws { try await compareNativeVocabulary(live: true) }

    private func compareNativeVocabulary(live: Bool) async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use --only asr-vocabulary for installed-model vocabulary checks")
        #else
        let settings = Settings.shared
        let saved = (settings.parakeetModelChoice, settings.selectedLanguage,
                     settings.transcriptPostProcessingMode, settings.customVocabulary)
        defer {
            settings.parakeetModelChoice = saved.0; settings.selectedLanguage = saved.1
            settings.transcriptPostProcessingMode = saved.2; settings.customVocabulary = saved.3
        }
        settings.parakeetModelChoice = .nemotronMultilingual
        settings.transcriptPostProcessingMode = .none
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: .nemotronMultilingual), "Install multilingual Nemotron first")
        try await engine.prepare()
        let iterations = max(1, min(10, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let fixtures = try GoldenSpeechFixture.all()
        let cases: [(String, [String])] = [("golden-en-1", ["Quilter"]),
            ("golden-en-fleurs-2", ["Chandra Shekhar Solanki"]),
            ("golden-en-ami-3", ["David", "Andrew", "Craig"])]
        for (id, genuineTerms) in cases {
            let fixture = try XCTUnwrap(fixtures.first { $0.id == id })
            settings.selectedLanguage = .english
            for iteration in 0..<iterations {
                var errors: [String: Double] = [:]
                for (variant, terms) in [("baseline", [String]()), ("genuine", genuineTerms),
                                         ("distractors", ["CRAN", "ran", "NVIDIA", "cancellation"]),
                                         ("short_cran", ["CRAN"]), ("short_ran", ["ran"]),
                                         ("nvidia", ["NVIDIA"]), ("cancellation", ["cancellation"]),
                                         ("cleared", [String]())] {
                    settings.transcriptPostProcessingMode = terms.isEmpty ? .none : .fluidAudioVocabulary
                    settings.customVocabulary = terms
                    let preparation = ContinuousClock.now
                    try await engine.prepare()
                    let preparationMs = BenchmarkStatistics.elapsedMilliseconds(from: preparation)
                    let before = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    let output: String
                    if live {
                        try await engine.beginStreamingReplayForTesting()
                        let reader = try RecoveryAudioReader(url: fixture.audioURL)
                        while let chunk = try reader.nextSamples(maxSamples: 16_000) {
                            try await engine.replayStreamingAudioForTesting(chunk)
                        }
                        output = await engine.stopRecording()
                    } else { output = try await engine.transcribeRecording(at: fixture.audioURL) }
                    let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let after = try BenchmarkProcessResources.sample()
                    let error = try fixture.errorRate(hypothesis: output)
                    errors[variant] = error
                    try emit(["experiment": "native_vocabulary", "model": "nemotronMultilingual",
                        "fixture": id, "variant": variant, "terms": terms, "iteration": iteration,
                        "path": live ? "production_live" : "production_file", "preparation_ms": preparationMs,
                        "native_weight": ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_NATIVE_VOCAB_WEIGHT"] ?? "1",
                        "latency_ms": elapsed, "cpu_ms": after.cpuMilliseconds - before.cpuMilliseconds,
                        "process_peak_rss_bytes": after.peakResidentBytes, "error_rate": error, "output": output,
                        "audio_sha256": fixture.audioSHA256, "reference_sha256": fixture.referenceSHA256])
                    XCTAssertFalse(output.isEmpty)
                }
                for variant in ["genuine", "distractors", "short_cran", "short_ran", "nvidia", "cancellation", "cleared"] {
                    XCTAssertLessThanOrEqual(try XCTUnwrap(errors[variant]), try XCTUnwrap(errors["baseline"]),
                                             "Vocabulary regression: \(id)/\(variant)")
                }
            }
        }
        await engine.cancel()
        #endif
    }

    #if PIPELINE_BENCHMARK
    private func emit(_ row: [String: Any]) throws {
        print("MODEL_VOCABULARY_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
    #endif
}

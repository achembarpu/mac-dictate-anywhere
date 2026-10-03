import Foundation
import XCTest
@testable import Dictate_Anywhere

/// The production recording-file path without repeated live preview work.
/// Use the same goldens/scorer as external-asr-quality for runtime comparisons.
@MainActor
final class GoldenFileASRBenchmarkTests: XCTestCase {
    func testInstalledModelsDecodeCompleteGoldenFiles() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --release --only asr-file")
        #else
        let environment = ProcessInfo.processInfo.environment
        let name = environment["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"
        let models = name == "all" ? ParakeetModelChoice.allCases : [try XCTUnwrap(ParakeetModelChoice(rawValue: name))]
        let iterations = max(1, min(10, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let languages = environment["PIPELINE_BENCHMARK_LANGUAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        var fixtures = try GoldenSpeechFixture.all()
        if let selection = environment["PIPELINE_BENCHMARK_FIXTURE"] {
            let ids = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard Set(ids).count == ids.count else {
                XCTFail("Select each golden fixture once")
                return
            }
            fixtures = try ids.map { id in
                try XCTUnwrap(fixtures.first { $0.id == id }, "Select exact golden IDs")
            }
        }
        if let languages { fixtures = fixtures.filter { languages.contains($0.language) } }
        let settings = Settings.shared
        let originalModel = settings.parakeetModelChoice
        let originalLanguage = settings.selectedLanguage
        defer { settings.parakeetModelChoice = originalModel; settings.selectedLanguage = originalLanguage }
        var ran = 0
        for model in models {
            let engine = ParakeetEngine()
            guard model.isAvailableOnThisMac, engine.checkModelOnDisk(for: model) else { continue }
            settings.parakeetModelChoice = model
            try await engine.prepare()
            for fixture in fixtures where fixture.supports(model) {
                settings.selectedLanguage = SupportedLanguage(rawValue: fixture.language) ?? .chinese
                let url = try fixture.audioURL
                // Exercise this whole-file shape outside the warm timer.
                let firstStart = ContinuousClock.now
                _ = try await engine.transcribeRecording(at: url)
                let firstMs = BenchmarkStatistics.elapsedMilliseconds(from: firstStart)
                var latencies: [Double] = []
                for iteration in 0..<iterations {
                    let resourcesBefore = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    let output = try await engine.transcribeRecording(at: url)
                    let latency = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let resourcesAfter = try BenchmarkProcessResources.sample()
                    latencies.append(latency)
                    XCTAssertFalse(output.isEmpty, "\(model.rawValue)/\(fixture.id)")
                    let row: [String: Any] = ["model": model.rawValue, "fixture": fixture.id,
                        "iteration": iteration, "latency_ms": latency, "first_file_ms": firstMs,
                        "audio_seconds": Double(fixture.sampleCount) / 16_000,
                        "cpu_ms": resourcesAfter.cpuMilliseconds - resourcesBefore.cpuMilliseconds,
                        "process_peak_rss_bytes": resourcesAfter.peakResidentBytes,
                        "error_rate": try fixture.errorRate(hypothesis: output), "output": output,
                        "path": "production_recording_file"]
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print("ASR_FILE_RESULT " + String(decoding: data, as: UTF8.self))
                    ran += 1
                }
                BenchmarkStatistics(latencies).report(component: "golden_file_asr", details: "model=\(model.rawValue) fixture=\(fixture.id)")
            }
            // Model ownership is recording-engine scoped. The next iteration
            // releases this engine rather than retaining a model ensemble.
        }
        try XCTSkipUnless(ran > 0, "No installed model supports the selected files")
        #endif
    }
}

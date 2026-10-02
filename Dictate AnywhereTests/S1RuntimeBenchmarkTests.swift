import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1RuntimeBenchmarkTests: XCTestCase {
    func testPairedRuntimeGoldenCleanup() async throws {
        #if !PIPELINE_BENCHMARK || !arch(arm64)
        throw XCTSkip("Use scripts/dev.sh benchmark --release --only s1-runtime on Apple Silicon")
        #else
        let env = ProcessInfo.processInfo.environment
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "5") ?? 5))
        let manager = S1MiniModelManager()
        let mlxURL = env["S1_MLX_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? S1MiniRuntime.mlx.modelURL(in: manager.modelDirectory)
        let llamaURL = env["S1_MINI_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? manager.modelDirectory.appendingPathComponent(S1MiniModelSpec.filename)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mlxURL.path)
            && FileManager.default.fileExists(atPath: llamaURL.path), "Install both S1 formats or specify paths")
        await S1MiniPostProcessingService.unload()
        let mlx = S1MiniMLXInferenceEngine.shared
        let llamaPrepared = await S1MiniPostProcessingService.prewarm(modelURL: llamaURL)
        let mlxPrepared = await S1MiniPostProcessingService.prewarm(modelURL: mlxURL)
        XCTAssertTrue(llamaPrepared && mlxPrepared)
        let modes = ["llama", "llama-f16", "mlx", "mlx-uncached"]
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() + GoldenCleanupFixture.s1Stress()
            where fixture.language == "en" && fixture.vocabulary == nil {
            if let filter = env["PIPELINE_BENCHMARK_FIXTURE"], filter != fixture.id { continue }
            var samples: [String: [Double]] = [:]
            var outputs: [String: String] = [:]
            for iteration in 0..<iterations {
                for mode in iteration.isMultiple(of: 2) ? modes : Array(modes.reversed()) {
                    await mlx.configureForTesting(prefix: mode != "mlx-uncached", prefill: 256)
                    if mode.hasPrefix("llama") {
                        await S1MiniInferenceEngine.shared.configureCacheForTesting(f16: mode == "llama-f16")
                        let prepared = await S1MiniPostProcessingService.prewarm(modelURL: llamaURL)
                        XCTAssertTrue(prepared)
                    }
                    let started = ContinuousClock.now
                    let output = try await S1MiniPostProcessingService.process(text: fixture.input,
                        modelURL: mode.hasPrefix("llama") ? llamaURL : mlxURL, styling: .semiFormal,
                        structure: .prose, contextSetting: .general, context: nil)
                    let latency = BenchmarkStatistics.elapsedMilliseconds(from: started)
                    samples[mode, default: []].append(latency)
                    if let previous = outputs[mode] { XCTAssertEqual(output, previous, "Non-deterministic \(fixture.id)/\(mode)") }
                    outputs[mode] = output
                    let row: [String: Any] = ["fixture": fixture.id, "mode": mode, "iteration": iteration,
                        "latency_ms": latency, "output": output, "issues": fixture.violations(in: output),
                        "lost_facts": fixture.lostFacts(in: output),
                        "error_rate": GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output, metric: .wer)]
                    print("S1_RUNTIME_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                    ran += 1
                }
            }
            // Prefix caching must preserve this decoder's output exactly.
            XCTAssertEqual(outputs["mlx"], outputs["mlx-uncached"], fixture.id)
            let baselineIssues = Set(fixture.violations(in: try XCTUnwrap(outputs["llama"])))
            let newIssues = Set(fixture.violations(in: try XCTUnwrap(outputs["mlx"])))
            XCTAssertTrue(newIssues.isSubset(of: baselineIssues), "New regression in \(fixture.id): \(newIssues.subtracting(baselineIssues))")
            for mode in modes {
                BenchmarkStatistics(try XCTUnwrap(samples[mode])).report(component: "s1_runtime", details: "fixture=\(fixture.id) mode=\(mode)")
            }
        }
        await S1MiniInferenceEngine.shared.configureCacheForTesting(f16: false)
        await mlx.configureForTesting(prefix: true, prefill: 256)
        await S1MiniPostProcessingService.unload()
        XCTAssertGreaterThan(ran, 0)
        #endif
    }
}

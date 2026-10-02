import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1RuntimeBenchmarkTests: XCTestCase {
    private static let allModes = ["llama", "llama-f16", "mlx", "mlx-uncached"]

    private static func selectedModes(_ selection: String?) throws -> [String] {
        guard let selection else { return allModes }
        let modes = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !modes.isEmpty, Set(modes).count == modes.count,
              modes.allSatisfy(allModes.contains) else {
            throw NSError(domain: "S1RuntimeBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "PIPELINE_BENCHMARK_S1_MODES must contain unique comma-separated modes: \(allModes.joined(separator: ","))"])
        }
        return modes
    }

    func testModeSelectionRejectsTyposAndDuplicateWork() throws {
        XCTAssertEqual(try Self.selectedModes(nil), Self.allModes)
        XCTAssertEqual(try Self.selectedModes("mlx,mlx-uncached"), ["mlx", "mlx-uncached"])
        for invalid in ["", "mlx,", "mlx,mlx", "mlxx", "mlx, llama"] {
            XCTAssertThrowsError(try Self.selectedModes(invalid))
        }
    }

    func testPairedRuntimeGoldenCleanup() async throws {
        #if !PIPELINE_BENCHMARK || !arch(arm64)
        throw XCTSkip("Use scripts/dev.sh benchmark --release --only s1-runtime on Apple Silicon")
        #else
        let env = ProcessInfo.processInfo.environment
        let modes = try Self.selectedModes(env["PIPELINE_BENCHMARK_S1_MODES"])
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "5") ?? 5))
        let manager = S1MiniModelManager()
        let mlxURL = env["S1_MLX_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? S1MiniRuntime.mlx.modelURL(in: manager.modelDirectory)
        let llamaURL = env["S1_MINI_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? manager.modelDirectory.appendingPathComponent(S1MiniModelSpec.filename)
        let needsMLX = modes.contains { $0.hasPrefix("mlx") }
        let needsLlama = modes.contains { $0.hasPrefix("llama") }
        try XCTSkipUnless(!needsMLX || FileManager.default.fileExists(atPath: mlxURL.path), "Install the selected MLX format or specify its path")
        try XCTSkipUnless(!needsLlama || FileManager.default.fileExists(atPath: llamaURL.path), "Install the selected llama format or specify its path")
        await S1MiniPostProcessingService.unload()
        let mlx = S1MiniMLXInferenceEngine.shared
        if needsLlama {
            let prepared = await S1MiniPostProcessingService.prewarm(modelURL: llamaURL)
            XCTAssertTrue(prepared)
        }
        if needsMLX {
            let prepared = await S1MiniPostProcessingService.prewarm(modelURL: mlxURL)
            XCTAssertTrue(prepared)
        }
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
                    let resourcesBefore = try BenchmarkProcessResources.sample()
                    let started = ContinuousClock.now
                    let output = try await S1MiniPostProcessingService.process(text: fixture.input,
                        modelURL: mode.hasPrefix("llama") ? llamaURL : mlxURL, styling: .semiFormal,
                        structure: .prose, contextSetting: .general, context: nil)
                    let latency = BenchmarkStatistics.elapsedMilliseconds(from: started)
                    let resourcesAfter = try BenchmarkProcessResources.sample()
                    samples[mode, default: []].append(latency)
                    if let previous = outputs[mode] { XCTAssertEqual(output, previous, "Non-deterministic \(fixture.id)/\(mode)") }
                    outputs[mode] = output
                    let row: [String: Any] = ["fixture": fixture.id, "mode": mode, "iteration": iteration,
                        "latency_ms": latency, "output": output, "issues": fixture.violations(in: output),
                        "cpu_ms": resourcesAfter.cpuMilliseconds - resourcesBefore.cpuMilliseconds,
                        "process_peak_rss_bytes": resourcesAfter.peakResidentBytes,
                        "lost_facts": fixture.lostFacts(in: output),
                        "error_rate": GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output, metric: .wer)]
                    print("S1_RUNTIME_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                    ran += 1
                }
            }
            // Prefix caching must preserve this decoder's output exactly.
            if let cached = outputs["mlx"], let fresh = outputs["mlx-uncached"] {
                XCTAssertEqual(cached, fresh, fixture.id)
            }
            for mode in modes {
                let output = try XCTUnwrap(outputs[mode])
                let issues = Set(fixture.violations(in: output))
                let lost = Set(fixture.lostFacts(in: output))
                if let baseline = outputs["llama"] {
                    XCTAssertTrue(issues.isSubset(of: Set(fixture.violations(in: baseline))), "New regression in \(fixture.id)/\(mode)")
                    XCTAssertTrue(lost.isSubset(of: Set(fixture.lostFacts(in: baseline))), "Lost facts in \(fixture.id)/\(mode)")
                } else {
                    XCTAssertTrue(issues.isEmpty, "Quality violation in \(fixture.id)/\(mode): \(issues)")
                    XCTAssertTrue(lost.isEmpty, "Lost facts in \(fixture.id)/\(mode): \(lost)")
                }
            }
            for mode in modes {
                BenchmarkStatistics(try XCTUnwrap(samples[mode])).report(component: "s1_runtime", details: "fixture=\(fixture.id) mode=\(mode)")
            }
        }
        await S1MiniInferenceEngine.shared.configureCacheForTesting(f16: nil)
        await mlx.configureForTesting(prefix: true, prefill: 256)
        await S1MiniPostProcessingService.unload()
        XCTAssertGreaterThan(ran, 0)
        #endif
    }
}

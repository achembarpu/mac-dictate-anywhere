#if PIPELINE_BENCHMARK
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1CPUBenchmarkTests: XCTestCase {
    func testCPUCachePrecisionComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let manager = S1MiniModelManager(recommendedRuntime: .llama)
        let url = env["S1_MINI_MODEL_PATH"].map { URL(fileURLWithPath: $0) } ?? manager.modelURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Install S1 GGUF or specify its path")
        let engine = S1MiniInferenceEngine.shared
        await engine.configureCPUForTesting(true)
        var ran = 0
        for fixture in try GoldenCleanupFixture.all()
            where fixture.language == "en" && fixture.vocabulary == nil {
            if let filter = env["PIPELINE_BENCHMARK_FIXTURE"], filter != fixture.id { continue }
            var outputs: [String: String] = [:]
            for iteration in 0..<iterations {
                for f16 in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let mode = f16 ? "cpu-f16" : "cpu-q8"
                    await engine.configureCacheForTesting(f16: f16)
                    try await engine.prewarm(from: url)
                    let start = ContinuousClock.now
                    let output = try await S1MiniPostProcessingService.process(text: fixture.input, modelURL: url,
                        styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil)
                    let ms = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let issues = fixture.violations(in: output)
                    XCTAssertTrue(issues.isEmpty, "\(fixture.id)/\(mode): \(issues)")
                    if let previous = outputs[mode] { XCTAssertEqual(output, previous) }
                    outputs[mode] = output
                    let row: [String: Any] = ["fixture": fixture.id, "mode": mode, "iteration": iteration,
                        "latency_ms": ms, "output": output, "issues": issues, "threads": S1MiniCPUConfiguration.threadCount]
                    print("S1_CPU_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                    ran += 1
                }
            }
        }
        await engine.configureCacheForTesting(f16: nil)
        await engine.configureCPUForTesting(false)
        await engine.unload()
        XCTAssertGreaterThan(ran, 0)
    }
}
#endif

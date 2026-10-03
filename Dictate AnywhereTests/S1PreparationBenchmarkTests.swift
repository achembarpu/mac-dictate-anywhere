#if PIPELINE_BENCHMARK
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1PreparationBenchmarkTests: XCTestCase {
    func testColdEngineVersusPreparedFirstRequest() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --release --only s1-prepare")
        #else
        let env = ProcessInfo.processInfo.environment
        let manager = S1MiniModelManager()
        let url: URL
        if let path = env["S1_MLX_MODEL_PATH"] ?? env["S1_MINI_MODEL_PATH"] { url = URL(fileURLWithPath: path) }
        else { url = try await manager.validatedModelURL() }
        let text = "please send invoice 4182 to Mara on October 14 and do not include the draft"
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        for iteration in 0..<iterations {
            await S1MiniPostProcessingService.unload()
            let coldStart = ContinuousClock.now
            let cold = try await cleanup(text, url: url)
            let coldMS = BenchmarkStatistics.elapsedMilliseconds(from: coldStart)
            await S1MiniPostProcessingService.unload()
            let prepareStart = ContinuousClock.now
            let prepared = await S1MiniPostProcessingService.prewarm(modelURL: url)
            let prepareMS = BenchmarkStatistics.elapsedMilliseconds(from: prepareStart)
            XCTAssertTrue(prepared)
            var requests: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                let output = try await cleanup(text, url: url)
                requests.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
                XCTAssertEqual(output, cold)
                XCTAssertTrue(output.contains("4182") && output.contains("Mara"))
            }
            let row: [String: Any] = ["iteration": iteration, "cold_engine_ms": coldMS,
                "preparation_ms": prepareMS, "prepared_first_request_ms": requests[0],
                "steady_request_ms": Array(requests.dropFirst()), "output": cold,
                "runtime": url.pathExtension == "gguf" ? "llama" : "mlx"]
            print("S1_PREPARATION_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
        await S1MiniPostProcessingService.unload()
        #endif
    }

    private func cleanup(_ text: String, url: URL) async throws -> String {
        try await S1MiniPostProcessingService.process(text: text, modelURL: url, styling: .semiFormal,
            structure: .prose, contextSetting: .general, context: nil)
    }
}
#endif

import Foundation
import XCTest
@testable import Dictate_Anywhere

/// Compare allocation policies with identical weights, prompt, decoder and
/// golden inputs. Never unload weights inside a timed request.
@MainActor
final class S1ContextBenchmarkTests: XCTestCase {
    func testPairedFreshAndReusedContextGoldenCleanup() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --release --only s1-context")
        #else
        let environment = ProcessInfo.processInfo.environment
        let iterations = max(1, min(10, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "5") ?? 5))
        let manager = S1MiniModelManager()
        let url: URL
        if let path = environment["S1_MINI_MODEL_PATH"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            try XCTSkipUnless(manager.isModelDownloaded, "Install S1-mini in the app first")
            url = try await manager.validatedModelURL()
        }
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() where fixture.language == "en" && fixture.vocabulary == nil {
            if let filter = environment["PIPELINE_BENCHMARK_FIXTURE"], filter != fixture.id { continue }
            let chunks = try await engine.transcriptChunks(fixture.input, modelURL: url)
            var samples: [String: [Double]] = ["fresh": [], "reuse": []]
            var referenceOutput: String?
            for iteration in 0..<iterations {
                let modes = iteration.isMultiple(of: 2) ? ["fresh", "reuse"] : ["reuse", "fresh"]
                for mode in modes {
                    // Both modes begin with a warm graph. Fresh discards that
                    // allocation at every chunk, including free cost in timing.
                    try await engine.prewarm(from: url)
                    let started = ContinuousClock.now
                    var outputs: [String] = []
                    for chunk in chunks {
                        if mode == "fresh" { await engine.discardInferenceContextForTesting() }
                        outputs.append(try await S1MiniPostProcessingService.process(
                            text: chunk, modelURL: url, styling: .semiFormal,
                            structure: .prose, contextSetting: .general, context: nil
                        ))
                        if mode == "fresh" { await engine.discardInferenceContextForTesting() }
                    }
                    let output = outputs.joined(separator: " ")
                    let latency = BenchmarkStatistics.elapsedMilliseconds(from: started)
                    samples[mode, default: []].append(latency)
                    if let referenceOutput { XCTAssertEqual(output, referenceOutput, "\(fixture.id)/\(mode)") }
                    else { referenceOutput = output }
                    let issues = fixture.violations(in: output)
                    let lost = fixture.lostFacts(in: output)
                    XCTAssertTrue(issues.isEmpty, "\(fixture.id): \(issues)")
                    XCTAssertTrue(lost.isEmpty, "\(fixture.id): \(lost)")
                    let row: [String: Any] = ["fixture": fixture.id, "mode": mode, "iteration": iteration,
                        "latency_ms": latency, "chunks": chunks.count, "output": output,
                        "issues": issues, "lost_facts": lost,
                        "error_rate": GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output, metric: .wer)]
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print("S1_CONTEXT_RESULT " + String(decoding: data, as: UTF8.self))
                    ran += 1
                }
            }
            for mode in ["fresh", "reuse"] {
                BenchmarkStatistics(try XCTUnwrap(samples[mode])).report(component: "s1_context", details: "fixture=\(fixture.id) mode=\(mode)")
            }
        }
        await engine.unload()
        XCTAssertGreaterThan(ran, 0)
        #endif
    }
}

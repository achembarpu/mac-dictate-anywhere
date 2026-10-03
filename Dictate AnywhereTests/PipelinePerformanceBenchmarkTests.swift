#if PIPELINE_BENCHMARK
import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Deterministic benchmarks for pipeline work that does not require a real
/// target application, Accessibility, microphone, or Core Audio routing.
@MainActor
final class PipelinePerformanceBenchmarkTests: XCTestCase {
    private var iterations: Int {
        max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
    }

    func testAudioPollingBenchmark() throws {
        let sampleWindow = Array((0..<1_600).map { index in
            sin(Float(index) * 0.03) * 0.08
        })
        let updateCount = iterations * 1_000
        let monitor = AudioMonitor()
        var meaningfulUpdateCount = 0
        var lastDisplayedLevel: Float?
        let startedAt = ContinuousClock.now

        for _ in 0..<updateCount {
            monitor.update(samples: sampleWindow[...])
            let shouldDisplay = AudioMonitor.hasMeaningfulLevelChange(
                from: lastDisplayedLevel, to: monitor.smoothedLevel
            )
            if shouldDisplay {
                meaningfulUpdateCount += 1
                lastDisplayedLevel = monitor.smoothedLevel
            }
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertGreaterThan(meaningfulUpdateCount, 0)
        XCTAssertLessThanOrEqual(meaningfulUpdateCount, updateCount)
        print(
            "PIPELINE_BENCHMARK component=audio_polling iterations=\(updateCount) "
            + "meaningful_updates=\(meaningfulUpdateCount) elapsed=\(elapsed)"
        )
    }

    func testS1MiniPrewarmBenchmark() async throws {
        let modelURL: URL
        if let path = ProcessInfo.processInfo.environment["S1_MINI_MODEL_PATH"], !path.isEmpty {
            modelURL = URL(fileURLWithPath: path)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "S1-mini model path does not exist")
        } else {
            let manager = S1MiniModelManager()
            try XCTSkipUnless(manager.isModelDownloaded, "S1-mini is not installed")
            modelURL = try await manager.validatedModelURL()
        }

        let startedAt = ContinuousClock.now
        let modelReady = await S1MiniPostProcessingService.prewarm(modelURL: modelURL)
        let elapsed = startedAt.duration(to: .now)
        XCTAssertTrue(modelReady, "S1-mini model failed to prewarm")
        print("PIPELINE_BENCHMARK component=s1_mini_prewarm elapsed=\(elapsed)")
        let firstCleanup = ContinuousClock.now
        let output = try await S1MiniPostProcessingService.process(
            text: "Um, I think we should send the report tomorrow.", modelURL: modelURL,
            styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil
        )
        let requestElapsed = firstCleanup.duration(to: .now)
        XCTAssertTrue(output.lowercased().contains("tomorrow"))
        XCTAssertFalse(output.lowercased().contains("hello"), "Synthetic warmup leaked into cleanup")
        print("PIPELINE_BENCHMARK component=s1_mini_first_cleanup_after_prewarm elapsed=\(requestElapsed)")
        await S1MiniPostProcessingService.unload()
    }
}
#endif

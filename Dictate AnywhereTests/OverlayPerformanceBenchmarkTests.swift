#if PIPELINE_BENCHMARK
import XCTest
@testable import Dictate_Anywhere

/// Current suffix derivation cost; Unicode correctness and Observation are in the regular suite.
@MainActor
final class OverlayPerformanceBenchmarkTests: XCTestCase {
    func testPreviewSuffixBenchmark() {
        let rounds = min(10, max(3, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "5") ?? 5))
        let calls = 500
        var checksum = 0
        for (name, pattern, length) in [
            ("english_short", "Meeting notes for the project team. ", 4_096),
            ("english_long", "Meeting notes for the project team. ", 16_384),
            ("cjk_long", "这是用于衡量长时间听写预览的文本。", 16_384)
        ] {
            let text = String(String(repeating: pattern, count: length / pattern.count + 1).prefix(length))
            let inputs = (0..<4).map { String($0) + text }
            var times: [Double] = []
            for _ in 0..<rounds {
                for call in 0..<20 { checksum &+= OverlayPreviewText.trimmed(inputs[call % inputs.count]).utf8.count }
                let start = DispatchTime.now().uptimeNanoseconds
                for call in 0..<calls { checksum &+= OverlayPreviewText.trimmed(inputs[call % inputs.count]).utf8.count }
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls) / 1_000)
            }
            print("PIPELINE_BENCHMARK component=overlay_preview fixture=\(name) characters=\(length + 1) "
                + "calls_per_round=\(calls) rounds=\(rounds) median_us=\(times.sorted()[rounds / 2])")
        }
        XCTAssertGreaterThan(checksum, 0)
    }
}
#endif

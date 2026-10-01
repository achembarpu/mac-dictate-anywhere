import XCTest
@testable import Dictate_Anywhere

/// Compares the shipped helper with the pre-change algorithm on identical text.
/// This measures suffix derivation, not SwiftUI rendering or whole-app CPU.
@MainActor
final class OverlayPerformanceBenchmarkTests: XCTestCase {
    func testPreviewSuffixBenchmark() throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark --only overlay to enable overlay benchmarks")
        #else
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
            for input in inputs {
                XCTAssertEqual(OverlayPreviewText.trimmed(input), oldPreview(input))
            }
            var oldTimes: [Double] = []
            var boundedTimes: [Double] = []
            for round in 0..<rounds {
                // Alternate order to limit systematic warm-up/thermal bias.
                if round.isMultiple(of: 2) {
                    oldTimes.append(time(inputs, calls: calls, checksum: &checksum, operation: oldPreview))
                    boundedTimes.append(time(inputs, calls: calls, checksum: &checksum, operation: OverlayPreviewText.trimmed))
                } else {
                    boundedTimes.append(time(inputs, calls: calls, checksum: &checksum, operation: OverlayPreviewText.trimmed))
                    oldTimes.append(time(inputs, calls: calls, checksum: &checksum, operation: oldPreview))
                }
            }
            let old = oldTimes.sorted()[rounds / 2]
            let bounded = boundedTimes.sorted()[rounds / 2]
            print(
                "PIPELINE_BENCHMARK component=overlay_preview fixture=\(name) "
                + "characters=\(length + 1) calls_per_round=\(calls) rounds=\(rounds) "
                + "old_median_us=\(old) bounded_median_us=\(bounded) ratio=\(old / bounded)"
            )
        }
        XCTAssertGreaterThan(checksum, 0)
        #endif
    }

    /// Historical comparison only. This algorithm is intentionally not in app code.
    @inline(never)
    private func oldPreview(_ transcript: String) -> String {
        guard !transcript.isEmpty else { return "" }
        let limit = OverlayPreviewText.maximumCharacters
        guard transcript.count > limit else { return transcript }
        return "..." + String(transcript.suffix(limit))
    }

    private func time(
        _ inputs: [String], calls: Int, checksum: inout Int, operation: (String) -> String
    ) -> Double {
        for call in 0..<20 { checksum &+= operation(inputs[call % inputs.count]).utf8.count }
        let start = DispatchTime.now().uptimeNanoseconds
        for call in 0..<calls { checksum &+= operation(inputs[call % inputs.count]).utf8.count }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls) / 1_000
    }
}

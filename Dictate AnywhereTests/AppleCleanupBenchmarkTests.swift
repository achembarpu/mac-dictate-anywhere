#if PIPELINE_BENCHMARK
import FoundationModels
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class AppleCleanupBenchmarkTests: XCTestCase {
    func testGoldenCleanupAndPreparedSessionIsolation() async throws {
        if ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_CLEANUP_PROVIDER"] != nil {
            throw XCTSkip("A different cleanup provider was selected")
        }
        guard #available(macOS 26, *), case .available = AIPostProcessingService.availability else {
            throw XCTSkip("Apple Intelligence is unavailable")
        }
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() {
            guard SystemLanguageModel.default.supportsLocale(Locale(identifier: fixture.language)) else { continue }
            let filter = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_FIXTURE"]
            guard filter == nil || filter == fixture.id else { continue }
            let warmStart = ContinuousClock.now
            let prepared = await AIPostProcessingService.prewarm(prompt: "", vocabulary: fixture.vocabulary ?? [])
            XCTAssertTrue(prepared)
            let preparationMs = BenchmarkStatistics.elapsedMilliseconds(from: warmStart)
            // Apple's documented minimum lead time. Not a product-path delay.
            try await Task.sleep(for: .seconds(1))
            let start = ContinuousClock.now
            var output = fixture.input
            var fallback = false
            do {
                output = try await AIPostProcessingService.process(
                    text: fixture.input, prompt: "", vocabulary: fixture.vocabulary ?? []
                )
            } catch {
                fallback = true // Match AppState's whole-original fallback.
                print("CLEANUP_ERROR provider=apple fixture=\(fixture.id) error=\(error.localizedDescription)")
            }
            let latencyMs = BenchmarkStatistics.elapsedMilliseconds(from: start)
            let issues = fixture.violations(in: output)
            let errorRate = GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output,
                metric: fixture.language == "zh" ? .cer : .wer)
            print("CLEANUP_GOLDEN provider=apple fixture=\(fixture.id) prepare_ms=\(preparationMs) latency_ms=\(latencyMs) fallback=\(fallback) error_rate=\(errorRate) changed=\(output != fixture.input) issues=\(issues.count) input_chars=\(fixture.input.count) output_chars=\(output.count)")
            XCTAssertFalse(fallback, "\(fixture.id): default cleanup failed and returned the original")
            XCTAssertTrue(fixture.lostFacts(in: output).isEmpty, "\(fixture.id): cleanup lost factual content")
            ran += 1
        }
        XCTAssertGreaterThan(ran, 0)
        // A different request must not reuse the preceding transcript or prompt.
        let unchanged = "Please send the final report to Nadia."
        let output = try await AIPostProcessingService.process(text: unchanged, prompt: "Keep the transcript unchanged.")
        XCTAssertEqual(output, unchanged)
        await AIPostProcessingService.discardPreparedSession()
    }

    func testLongInputAcrossContextWindows() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["PIPELINE_BENCHMARK_CLEANUP_PROVIDER"] != nil || environment["PIPELINE_BENCHMARK_FIXTURE"] != nil {
            throw XCTSkip("Run the full Apple cleanup quality group for the context-window case")
        }
        guard #available(macOS 26, *), case .available = AIPostProcessingService.availability else {
            throw XCTSkip("Apple Intelligence unavailable")
        }
        let fixture = try XCTUnwrap(GoldenCleanupFixture.all().first { $0.id == "long-complete-ending" })
        // Distinct invoice batches test preservation, not automatic removal
        // of identical accidentally repeated dictation.
        let batches = (0..<3).map { batch in
            let input = fixture.input.replacingOccurrences(of: "4182", with: String(4182 + batch * 100))
                .replacingOccurrences(of: "7391", with: String(7391 + batch * 100))
            return input.components(separatedBy: "\n\n").enumerated().map { paragraph, text in
                "Record \(1001 + batch * 100 + paragraph). " + text
            }.joined(separator: "\n\n")
        }
        let text = batches.joined(separator: "\n\n")
        let start = ContinuousClock.now
        let output = try await AIPostProcessingService.process(text: text, prompt: "")
        let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
        XCTAssertNotEqual(output, text, "Do not count returning the original as successful cleanup")
        XCTAssertTrue(fixture.lostFacts(in: output).isEmpty)
        let paragraphCount = fixture.input.components(separatedBy: "\n\n").count
        let anchors = (0..<3).flatMap { batch in
            ["amber telescope \(7391 + batch * 100)", "invoice \(4182 + batch * 100)"]
                + (0..<paragraphCount).map { String(1001 + batch * 100 + $0) }
        }
        // A thousands separator is a valid spelling of these numeric record
        // labels. Check their values and occurrence counts, not the heading.
        let normalizedOutput = output.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d)"#, with: "", options: .regularExpression)
        // Authored fixture text only; keep omitted numeric labels diagnosable.
        print("CLEANUP_CONTEXT_OUTPUT " + output.replacingOccurrences(of: "\n", with: "\\n"))
        for anchor in anchors {
            let expression = try NSRegularExpression(pattern: #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: anchor) + #"(?![\p{L}\d])"#)
            func occurrences(_ text: String) -> Int {
                expression.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            }
            XCTAssertGreaterThan(text.lowercased().components(separatedBy: anchor).count - 1, 0, "Fixture must actually contain its checked fact")
            XCTAssertEqual(occurrences(normalizedOutput), occurrences(text.lowercased()),
                           "Multi-session cleanup lost or duplicated a fact: \(anchor)")
        }
        let expectedEnding = fixture.reference.split(separator: ".").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        XCTAssertFalse(expectedEnding.isEmpty)
        XCTAssertTrue(output.lowercased().trimmingCharacters(in: .punctuationCharacters).hasSuffix(expectedEnding), "The final ending must survive all chunks")
        let errorRate = GoldenSpeechFixture.errorRate(reference: text, hypothesis: output, metric: .wer)
        XCTAssertLessThanOrEqual(errorRate, 0.15, "Long cleanup omitted or rewrote too much content")
        print("CLEANUP_CONTEXT provider=apple latency_ms=\(elapsed) input_chars=\(text.count) output_chars=\(output.count) error_rate=\(errorRate)")
    }
}
#endif

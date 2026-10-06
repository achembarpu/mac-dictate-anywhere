#if PIPELINE_BENCHMARK
import CryptoKit
import FoundationModels
import XCTest
@testable import Dictate_Anywhere

/// Compares prompt supplements through the production Apple cleanup path.
/// Candidate files and captured output belong in workspace evidence.
@MainActor
final class AppleCleanupPromptBenchmarkTests: XCTestCase {
    override func tearDown() async throws {
        if #available(macOS 26, *) {
            await AIPostProcessingService.discardPreparedSession()
        }
    }

    func testCandidatePromptsAgainstGoldenReferences() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PIPELINE_BENCHMARK_CLEANUP_PROVIDER"] == "apple",
              let path = env["PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH"] else {
            throw XCTSkip("Select apple and an external JSON prompt candidate file")
        }
        guard #available(macOS 26, *), case .available = AIPostProcessingService.availability else {
            throw XCTSkip("Apple Intelligence is unavailable")
        }
        let candidates = try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
        let manifest = try GoldenSpeechFixture.resource("cleanup-golden-manifest.json")
        let manifestHash = Self.hash(try Data(contentsOf: manifest))
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "1") ?? 1))
        let languages = env["PIPELINE_BENCHMARK_LANGUAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() {
            guard SystemLanguageModel.default.supportsLocale(Locale(identifier: fixture.language)) else { continue }
            if let languages, !languages.contains(fixture.language) { continue }
            if let filter = env["PIPELINE_BENCHMARK_FIXTURE"], filter != fixture.id { continue }
            for iteration in 0..<iterations {
                // Rotate the order without changing the system weights or
                // the production schema, request framing, and chunk planner.
                for offset in candidates.indices {
                    let candidate = candidates[(offset + iteration) % candidates.count]
                    let prepared = await AIPostProcessingService.prewarm(
                        prompt: candidate.prompt, vocabulary: fixture.vocabulary ?? [])
                    XCTAssertTrue(prepared)
                    try await Task.sleep(for: .seconds(1))
                    let start = ContinuousClock.now
                    var output = fixture.input
                    var error: String?
                    do {
                        output = try await AIPostProcessingService.process(
                            text: fixture.input, prompt: candidate.prompt, vocabulary: fixture.vocabulary ?? [])
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                    let row = Result(
                        candidate: candidate.id, promptSHA256: Self.hash(Data(candidate.prompt.utf8)),
                        manifestSHA256: manifestHash, fixture: fixture.id, language: fixture.language,
                        iteration: iteration, latencyMs: BenchmarkStatistics.elapsedMilliseconds(from: start),
                        errorRate: GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output,
                            metric: fixture.language == "zh" ? .cer : .wer),
                        changed: output != fixture.input, issues: fixture.violations(in: output),
                        lostFacts: fixture.lostFacts(in: output), error: error, output: output)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    print("APPLE_PROMPT_RESULT " + String(decoding: try encoder.encode(row), as: UTF8.self))
                    // Semantic quality is evidence to inspect, not proof
                    // supplied by merely completing a model response.
                    XCTAssertNil(error, "\(candidate.id)/\(fixture.id): original transcript preserved after failure")
                    ran += 1
                }
            }
        }
        XCTAssertGreaterThan(ran, 0)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Candidate: Decodable {
        let id: String
        let prompt: String
    }

    private struct Result: Encodable {
        let candidate: String, promptSHA256: String, manifestSHA256: String, fixture: String, language: String
        let iteration: Int
        let latencyMs: Double, errorRate: Double
        let changed: Bool
        let issues: [String], lostFacts: [String]
        let error: String?
        let output: String
    }
}
#endif

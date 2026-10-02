import Foundation
import CryptoKit
import XCTest
@testable import Dictate_Anywhere

/// Research harness, not a product override. External prompts stay outside the
/// repository and are evaluated verbatim, without the app's schema instructions.
@MainActor
final class CleanupPromptBenchmarkTests: XCTestCase {
    func testSavedCandidateOutputsUseGoldenScorer() throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --only cleanup-prompts")
        #else
        guard let path = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH"] else {
            throw XCTSkip("Select saved candidate outputs")
        }
        let report = try JSONDecoder().decode(SavedOutputs.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let manifest = try GoldenSpeechFixture.resource("cleanup-golden-manifest.json")
        let hash = SHA256.hash(data: try Data(contentsOf: manifest)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(report.manifestSHA256, hash, "Candidate used different fixture inputs")
        let fixtures = Dictionary(uniqueKeysWithValues: try GoldenCleanupFixture.all().map { ($0.id, $0) })
        XCTAssertFalse(report.rows.isEmpty)
        for row in report.rows {
            let fixture = try XCTUnwrap(fixtures[row.fixture])
            let issues = fixture.violations(in: row.output), lost = fixture.lostFacts(in: row.output)
            let rate = GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: row.output,
                metric: fixture.language == "zh" ? .cer : .wer)
            print("CLEANUP_SAVED model=\(row.model) fixture=\(row.fixture) iteration=\(row.iteration) latency_ms=\(row.latencyMs) error_rate=\(rate) completed=\(row.completed) issues=\(issues.count) lost_facts=\(lost.count)")
            XCTAssertTrue(row.completed, "\(row.fixture): saved generation did not finish")
            if !issues.isEmpty || !lost.isEmpty { print("CLEANUP_SAVED_ISSUES fixture=\(row.fixture) issues=\(issues) lost=\(lost) output=\(row.output)") }
        }
        #endif
    }

    func testExternalPromptAgainstProductionCleanup() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --only cleanup-prompts")
        #else
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH"] else { throw XCTSkip("Select an external prompt file") }
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let fenced = source.components(separatedBy: "```")
        let instructions = (fenced.count > 2 ? fenced[1] : source).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(instructions.isEmpty)
        let model = try XCTUnwrap(env["PIPELINE_BENCHMARK_CLEANUP_MODEL"])
        let label = URL(fileURLWithPath: path).lastPathComponent
        let baseURL = env["PIPELINE_BENCHMARK_CLEANUP_URL"] ?? OllamaPostProcessingService.defaultBaseURL
        let url = try XCTUnwrap(URL(string: baseURL)?.appendingPathComponent("api/generate"))
        try XCTSkipUnless(["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""), "Candidate evaluation requires a local server")
        let ready = await OllamaPostProcessingService.prewarm(baseURL: baseURL, model: model)
        XCTAssertTrue(ready)
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        print("CLEANUP_PROMPT_SOURCE label=\(label) sha256=\(hash) model=\(model)")
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "1") ?? 1))
        let maximumInputBytes = max(128, min(8_192, Int(env["PIPELINE_BENCHMARK_CLEANUP_INPUT_BYTES"] ?? "8192") ?? 8_192))
        let languages = env["PIPELINE_BENCHMARK_LANGUAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() {
            if let languages, !languages.contains(fixture.language) { continue }
            if let filter = env["PIPELINE_BENCHMARK_FIXTURE"], fixture.id != filter { continue }
            for iteration in 0..<iterations {
                // Alternate order; both sides use the same installed weights.
                for candidate in (iteration.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let start = ContinuousClock.now
                    var output = fixture.input
                    var completed = true
                    do {
                        if candidate {
                            let chunks = try await TranscriptCleanupPlan.chunks(fixture.input) { input in
                                let bytes = input.utf8.count
                                return bytes <= maximumInputBytes && instructions.utf8.count + bytes
                                    + TranscriptCleanupPlan.outputReserve(inputTokens: bytes) + 512 <= 8_192
                            }
                            var outputs: [String] = []
                            for chunk in chunks {
                                try Task.checkCancellation()
                                guard !chunk.text.isEmpty else { outputs.append(chunk.original); continue }
                                var request = URLRequest(url: url)
                                request.httpMethod = "POST"
                                request.timeoutInterval = 120
                                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                var options: [String: Any] = ["num_ctx": 8_192,
                                    "num_predict": TranscriptCleanupPlan.outputReserve(inputTokens: chunk.text.utf8.count)]
                                if env["PIPELINE_BENCHMARK_CLEANUP_GREEDY"] == "1" { options["temperature"] = 0 }
                                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model,
                                    "system": instructions, "prompt": chunk.text, "stream": false,
                                    "keep_alive": "10m", "options": options])
                                let (data, response) = try await URLSession.shared.data(for: request)
                                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                                    throw CleanupResponseError.incompleteResponse
                                }
                                let decoded = try JSONDecoder().decode(CandidateResponse.self, from: data)
                                guard decoded.done == true, decoded.doneReason == "stop", !decoded.response.isEmpty else {
                                    print("CLEANUP_PROMPT_INCOMPLETE fixture=\(fixture.id) reason=\(decoded.doneReason ?? "unknown") output_chars=\(decoded.response.count)")
                                    throw CleanupResponseError.incompleteResponse
                                }
                                outputs.append(chunk.replacingText(with: decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            output = outputs.joined()
                        } else {
                            output = try await OllamaPostProcessingService.process(text: fixture.input,
                                baseURL: baseURL, model: model,
                                prompt: "Remove filler words and correct punctuation. Preserve all factual details and final intent.",
                                vocabulary: fixture.vocabulary ?? [])
                        }
                    } catch {
                        completed = false
                        print("CLEANUP_PROMPT_ERROR candidate=\(candidate) fixture=\(fixture.id) error=\(error.localizedDescription)")
                    }
                    let issues = fixture.violations(in: output), lost = fixture.lostFacts(in: output)
                    let rate = GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output,
                        metric: fixture.language == "zh" ? .cer : .wer)
                    print("CLEANUP_PROMPT label=\(label) candidate=\(candidate) model=\(model) fixture=\(fixture.id) iteration=\(iteration) latency_ms=\(BenchmarkStatistics.elapsedMilliseconds(from: start)) error_rate=\(rate) completed=\(completed) changed=\(output != fixture.input) issues=\(issues.count) lost_facts=\(lost.count) output_chars=\(output.count)")
                    if !issues.isEmpty || !lost.isEmpty {
                        print("CLEANUP_PROMPT_ISSUES candidate=\(candidate) fixture=\(fixture.id) issues=\(issues) lost=\(lost) output=\(output)")
                    }
                    // Completion is a protocol gate. Candidate quality is
                    // reported, never counted as proof that it is safe to adopt.
                    XCTAssertTrue(completed, "\(fixture.id): incomplete generation (candidate=\(candidate)); original preserved")
                    ran += 1
                }
            }
        }
        XCTAssertGreaterThan(ran, 0)
        #endif
    }

    private struct CandidateResponse: Decodable {
        let response: String
        let done: Bool
        let doneReason: String?
        enum CodingKeys: String, CodingKey { case response, done; case doneReason = "done_reason" }
    }

    private struct SavedOutputs: Decodable {
        let manifestSHA256: String
        let rows: [Row]
        enum CodingKeys: String, CodingKey { case manifestSHA256 = "manifest_sha256", rows }
        struct Row: Decodable {
            let fixture: String, model: String, output: String
            let iteration: Int
            let latencyMs: Double
            let completed: Bool
            enum CodingKeys: String, CodingKey { case fixture, model, output, iteration, completed; case latencyMs = "latency_ms" }
        }
    }
}

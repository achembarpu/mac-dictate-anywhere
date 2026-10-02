import Foundation
import CryptoKit
import XCTest
@testable import Dictate_Anywhere

/// Optional local runtime evaluation using the same licensed fixtures and WER /
/// CER scorer as the app's native engines. Does not install or launch a server.
@MainActor
final class ExternalSpeechBenchmarkTests: XCTestCase {
    func testSavedFileOutputsUseGoldenScorer() throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --only external-asr-quality")
        #else
        guard let path = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ASR_RESULTS_PATH"] else {
            throw XCTSkip("Select saved external speech results")
        }
        let report = try JSONDecoder().decode(SavedResults.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let manifest = try GoldenSpeechFixture.resource("golden-speech-manifest.json")
        let hash = SHA256.hash(data: try Data(contentsOf: manifest)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(report.manifestSHA256, hash, "Candidate used different golden audio/references")
        let fixtures = Dictionary(uniqueKeysWithValues: try GoldenSpeechFixture.all().map { ($0.id, $0) })
        XCTAssertFalse(report.rows.isEmpty)
        for row in report.rows {
            let fixture = try XCTUnwrap(fixtures[row.fixture])
            XCTAssertFalse(row.output.isEmpty, row.fixture)
            let rate = try fixture.errorRate(hypothesis: row.output)
            let scored: [String: Any] = ["model": row.model, "fixture": row.fixture,
                "iteration": row.iteration, "latency_ms": row.latencyMs,
                "error_rate": rate, "metric": fixture.metric.rawValue, "output": row.output]
            let data = try JSONSerialization.data(withJSONObject: scored, options: [.sortedKeys])
            print("ASR_SAVED_RESULT " + String(decoding: data, as: UTF8.self))
        }
        #endif
    }

    func testLocalRuntimeGoldenSpeech() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --only external-asr-quality")
        #else
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["PIPELINE_BENCHMARK_ASR_URL"] else { throw XCTSkip("Select a local ASR endpoint") }
        let url = try XCTUnwrap(URL(string: rawURL)?.appendingPathComponent("audio/transcriptions"))
        try XCTSkipUnless(["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""), "Only local runtime evaluation is supported")
        let model = try XCTUnwrap(env["PIPELINE_BENCHMARK_MODEL"])
        let languages = Set((env["PIPELINE_BENCHMARK_LANGUAGES"] ?? "en").split(separator: ",").map(String.init))
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        var ran = 0
        for fixture in try GoldenSpeechFixture.all() {
            guard languages.contains(fixture.language) else { continue }
            if let filter = env["PIPELINE_BENCHMARK_FIXTURE"], fixture.id != filter { continue }
            let audio = try Data(contentsOf: fixture.audioURL)
            for iteration in 0..<iterations {
                let start = ContinuousClock.now
                let boundary = UUID().uuidString
                var body = Data()
                func append(_ string: String) { body.append(Data(string.utf8)) }
                for (name, value) in [("model", model), ("response_format", "verbose_json")] {
                    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
                }
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"golden.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
                body.append(audio)
                append("\r\n--\(boundary)--\r\n")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw CleanupResponseError.incompleteResponse
                }
                let decoded = try JSONDecoder().decode(Transcript.self, from: data)
                XCTAssertFalse(decoded.text.isEmpty, fixture.id)
                XCTAssertNotEqual(decoded.truncated, true, "Runtime exhausted its output budget")
                let rate = try fixture.errorRate(hypothesis: decoded.text)
                print("EXTERNAL_ASR_GOLDEN model=\(model) fixture=\(fixture.id) iteration=\(iteration) latency_ms=\(BenchmarkStatistics.elapsedMilliseconds(from: start)) error_rate=\(rate) output_chars=\(decoded.text.count) truncated=\(decoded.truncated.map(String.init) ?? "unknown")")
                ran += 1
            }
        }
        XCTAssertGreaterThan(ran, 0)
        #endif
    }

    private struct Transcript: Decodable { let text: String; let truncated: Bool? }

    private struct SavedResults: Decodable {
        let manifestSHA256: String
        let rows: [Row]
        enum CodingKeys: String, CodingKey { case manifestSHA256 = "manifest_sha256", rows }
        struct Row: Decodable {
            let fixture: String, model: String, output: String
            let iteration: Int
            let latencyMs: Double
            enum CodingKeys: String, CodingKey { case fixture, model, output, iteration; case latencyMs = "latency_ms" }
        }
    }
}

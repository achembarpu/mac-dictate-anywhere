#if PIPELINE_BENCHMARK
import XCTest
@testable import Dictate_Anywhere

/// Real provider calls through the app's production services. Explicit opt-in
/// prevents unit tests from downloading models or spending API credits.
@MainActor
final class ProviderCleanupBenchmarkTests: XCTestCase {
    func testGoldenCleanupWithSelectedProvider() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let provider = environment["PIPELINE_BENCHMARK_CLEANUP_PROVIDER"] else { throw XCTSkip("Select a cleanup provider") }
        let model = environment["PIPELINE_BENCHMARK_CLEANUP_MODEL"] ?? ""
        let baseURL = environment["PIPELINE_BENCHMARK_CLEANUP_URL"] ?? OllamaPostProcessingService.defaultBaseURL
        let prompt = "Remove filler words and correct punctuation. Preserve all factual details and final intent."
        let iterations = max(1, min(10, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "1") ?? 1))
        let apiKey = environment["PIPELINE_BENCHMARK_CLEANUP_API_KEY"] ?? ""
        let preparationStart = ContinuousClock.now
        var s1URL: URL?
        switch provider {
        case "s1":
            let manager = S1MiniModelManager()
            try XCTSkipUnless(manager.isModelDownloaded, "Install S1-mini in the app first")
            s1URL = try await manager.validatedModelURL()
            let ready = await S1MiniPostProcessingService.prewarm(modelURL: try XCTUnwrap(s1URL))
            XCTAssertTrue(ready, "S1-mini could not prepare")
        case "ollama":
            XCTAssertFalse(model.isEmpty)
            let ready = await OllamaPostProcessingService.prewarm(baseURL: baseURL, model: model)
            XCTAssertTrue(ready, "Selected Ollama model could not preload")
        case "compatible":
            let ready = await OpenAICompatiblePostProcessingService.prewarm(baseURL: baseURL, model: model, apiKey: apiKey)
            XCTAssertTrue(ready, "Portable server did not report the selected model")
        case "openrouter":
            try XCTSkipIf(apiKey.isEmpty, "Explicit benchmark API key required for billable requests")
        default: throw XCTSkip("Choose s1, ollama, compatible or openrouter")
        }
        print("CLEANUP_PREPARATION provider=\(provider) model=\(model) latency_ms=\(BenchmarkStatistics.elapsedMilliseconds(from: preparationStart))")
        var ran = 0
        for fixture in try GoldenCleanupFixture.all() {
            if provider == "s1", fixture.language != "en" || fixture.vocabulary != nil { continue }
            // Meta's card names eight supported languages; Dutch/Chinese are
            // outside Llama 3.2's claimed coverage.
            if model.hasPrefix("llama3.2"), !["en", "de"].contains(fixture.language) { continue }
            if let filter = environment["PIPELINE_BENCHMARK_FIXTURE"], filter != fixture.id { continue }
            for iteration in 0..<iterations {
                let start = ContinuousClock.now
                let output: String
                switch provider {
                case "s1": output = try await S1MiniPostProcessingService.process(text: fixture.input,
                    modelURL: try XCTUnwrap(s1URL), styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil)
                case "ollama": output = try await OllamaPostProcessingService.process(text: fixture.input,
                    baseURL: baseURL, model: model, prompt: prompt, vocabulary: fixture.vocabulary ?? [])
                case "openrouter": output = try await OpenRouterPostProcessingService.process(text: fixture.input,
                    model: model, prompt: prompt, vocabulary: fixture.vocabulary ?? [], apiKey: apiKey, apiKeyEnvironmentVariable: "")
                default: output = try await OpenAICompatiblePostProcessingService.process(text: fixture.input,
                    baseURL: baseURL, model: model, apiKey: apiKey, prompt: prompt, vocabulary: fixture.vocabulary ?? [])
                }
                let latency = BenchmarkStatistics.elapsedMilliseconds(from: start)
                let issues = fixture.violations(in: output)
                let lost = fixture.lostFacts(in: output)
                let errorRate = GoldenSpeechFixture.errorRate(reference: fixture.reference, hypothesis: output,
                    metric: fixture.language == "zh" ? .cer : .wer)
                print("CLEANUP_GOLDEN provider=\(provider) model=\(model) fixture=\(fixture.id) iteration=\(iteration) latency_ms=\(latency) error_rate=\(errorRate) changed=\(output != fixture.input) issues=\(issues.count) lost_facts=\(lost.count) input_chars=\(fixture.input.count) output_chars=\(output.count)")
                if !issues.isEmpty || !lost.isEmpty { print("CLEANUP_ISSUES fixture=\(fixture.id) issues=\(issues) lost=\(lost) output=\(output)") }
                XCTAssertTrue(lost.isEmpty, "\(provider)/\(model)/\(fixture.id): lost facts: \(lost)")
                ran += 1
            }
        }
        XCTAssertGreaterThan(ran, 0)
        if provider == "s1" { await S1MiniPostProcessingService.unload() }
    }
}
#endif

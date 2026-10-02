import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

private struct HFTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private struct HFLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        HFTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct Fixture: Decodable {
    let id: String
    let language: String
    let input: String
    let vocabulary: [String]?
}

private struct Row: Codable, Sendable {
    let fixture: String
    let model: String
    let iteration: Int
    let latencyMs: Double
    let output: String
    let completed: Bool
    let inputTokens: Int
    let promptTokens: Int
    let outputTokens: Int
    let promptTokenSHA256: String
}

@main
struct S1MLXProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let iterations = Int(args[3]), (1...10).contains(iterations),
              let kvBits = Int(args[5]), [8, 16].contains(kvBits) else {
            throw NSError(domain: "S1MLXProbe", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: S1MLXProbe MODEL_DIRECTORY APP_REPO ITERATIONS OUTPUT_JSON KV_BITS(8|16)"])
        }
        let directory = URL(fileURLWithPath: args[1])
        let root = URL(fileURLWithPath: args[2])
        let manifest = try Data(contentsOf: root.appendingPathComponent("Dictate AnywhereTests/Fixtures/Golden/cleanup-golden-manifest.json"))
        let source = try String(contentsOf: root.appendingPathComponent("Dictate Anywhere/S1MiniPostProcessingService.swift"), encoding: .utf8)
        let line = try requireValue(source.components(separatedBy: "\n").first { $0.contains("static let systemPrompt = ") })
        let literal = try requireValue(line.components(separatedBy: " = ").last)
        let system = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        let start = ContinuousClock.now
        let container = try await loadModelContainer(from: directory, using: HFLoader())
        let loadingMs = elapsed(start)
        let label = "s1-mlx-swift-\(directory.lastPathComponent)-kv\(kvBits)"

        func run(_ text: String, fixture: String, iteration: Int) async throws -> Row {
            try await container.perform { context in
                let start = ContinuousClock.now
                let tokenizer = context.tokenizer
                let inputTokens = tokenizer.encode(text: text, addSpecialTokens: false).count
                guard inputTokens <= 1000 else { throw NSError(domain: "S1MLXProbe", code: 2) }
                let prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"
                    + "[Styling: semi-formal] [Structure: prose] [Context: general]\n\(text)<|im_end|>\n"
                    + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
                let tokens = tokenizer.encode(text: prompt, addSpecialTokens: false)
                let maximum = Int(ceil(Double(inputTokens) * 1.3)) + 32
                let stops = Set([tokenizer.eosTokenId, tokenizer.convertTokenToId("<|endoftext|>")].compactMap { $0 })
                let parameters = GenerateParameters(maxTokens: maximum + 1, kvBits: kvBits == 8 ? 8 : nil,
                                                    temperature: 0, prefillStepSize: 512)
                let stream = try generateTokens(input: LMInput(tokens: MLXArray(tokens)), parameters: parameters,
                                                context: context, includeStopToken: true)
                var generated: [Int] = []
                var completed = false
                for await item in stream {
                    if let token = item.token {
                        if stops.contains(token) { completed = generated.count <= maximum }
                        else { generated.append(token) }
                    }
                }
                let output = tokenizer.decode(tokenIds: Array(generated.prefix(maximum)), skipSpecialTokens: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let latency = elapsed(start)
                let tokenData = try JSONSerialization.data(withJSONObject: tokens)
                return Row(fixture: fixture, model: label, iteration: iteration, latencyMs: latency,
                           output: output, completed: completed, inputTokens: inputTokens,
                           promptTokens: tokens.count, outputTokens: generated.count,
                           promptTokenSHA256: digest(tokenData))
            }
        }

        let first = try await run("Hello.", fixture: "prewarm", iteration: 0)
        let warm = try await run("Hello.", fixture: "prewarm", iteration: 1)
        var rows: [Row] = []
        for fixture in try JSONDecoder().decode([Fixture].self, from: manifest)
            where fixture.language == "en" && fixture.vocabulary == nil {
            for iteration in 0..<iterations {
                let row = try await run(fixture.input, fixture: fixture.id, iteration: iteration)
                rows.append(row)
                print("\(label) \(fixture.id) \(iteration) \(row.latencyMs) ms completed=\(row.completed)")
            }
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let report: [String: Any] = ["manifest_sha256": digest(manifest), "loading_ms": loadingMs,
            "first_decode": try JSONSerialization.jsonObject(with: encoder.encode(first)),
            "prewarm_decode": try JSONSerialization.jsonObject(with: encoder.encode(warm)),
            "kv_bits": kvBits, "rows": try JSONSerialization.jsonObject(with: encoder.encode(rows))]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[4]))
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func requireValue<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "S1MLXProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Production prompt is missing"]) }
        return value
    }
}

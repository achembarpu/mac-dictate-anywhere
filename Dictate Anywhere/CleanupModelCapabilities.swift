import Foundation

nonisolated struct OllamaModelDetails: Decodable, Sendable {
    enum ThinkingValue: Decodable, Equatable, Sendable {
        case toggle(Bool)
        case level(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .toggle(value) }
            else { self = .level(try container.decode(String.self)) }
        }
        var jsonValue: Any {
            switch self { case .toggle(let value): return value; case .level(let value): return value }
        }
    }
    struct Thinking: Decodable, Sendable { let values: [ThinkingValue] }
    struct ModelInfo: Decodable, Sendable {
        let contextLength: Int?
        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            contextLength = values.allKeys.filter { $0.stringValue.hasSuffix(".context_length") }
                .compactMap { try? values.decode(Int.self, forKey: $0) }.filter { $0 > 0 }.min()
        }
    }
    let thinking: Thinking?
    let capabilities: [String]?
    let modelInfo: ModelInfo?
    enum CodingKeys: String, CodingKey { case thinking, capabilities; case modelInfo = "model_info" }

    var isKnownNonThinking: Bool {
        if let values = thinking?.values { return values == [.toggle(false)] }
        guard let capabilities, capabilities.contains("completion") else { return false }
        return !capabilities.contains("thinking")
    }

    /// A bounded dictation working set; don't allocate a model's entire training
    /// context (potentially hundreds of thousands of tokens) to clean a note.
    var cleanupContextLength: Int { min(8_192, modelInfo?.contextLength ?? 8_192) }

    var reasoningCapability: OllamaReasoningCapability {
        guard let values = thinking?.values else { return .unsupported }
        if values.contains(.toggle(true)) {
            return values.contains(.toggle(false)) ? .toggle : .required
        }
        if ["low", "medium", "high"].contains(where: { values.contains(.level($0)) }) { return .level }
        if values.contains(where: { if case .level = $0 { return true }; return false }) { return .required }
        return .unsupported
    }

    func thinkValue(for setting: OllamaReasoningSetting) -> ThinkingValue? {
        guard let values = thinking?.values else { return nil }
        let requested: ThinkingValue?
        switch setting {
        case .automatic: requested = nil
        case .disabled: requested = values.contains(.toggle(false)) ? .toggle(false) : nil
        case .enabled: requested = values.contains(.toggle(true)) ? .toggle(true) : nil
        case .low: requested = .level("low")
        case .medium: requested = .level("medium")
        case .high: requested = .level("high")
        }
        return requested.flatMap { values.contains($0) ? $0 : nil }
    }
}

/// Adapt only the parameter the server explicitly identifies as unsupported.
/// Never retry authentication, quota, context, refusal or generic 400 errors.
nonisolated enum CleanupRequestAdaptation {
    enum Parameter: Hashable { case structuredOutput, temperature }
    static func unsupportedParameter(in message: String) -> Parameter? {
        let text = message.lowercased()
        guard ["unsupported", "not supported", "not support", "not allowed", "only supports", "unknown parameter", "unrecognized"].contains(where: text.contains) else { return nil }
        if text.contains("temperature") { return .temperature }
        if text.contains("response_format") || text.contains("json_schema") || text.contains("structured output") {
            return .structuredOutput
        }
        // Ollama names its schema parameter `format`. A generic file, model
        // or audio format error does not reject that request parameter.
        let formatParameterErrors = [
            "format is not supported",
            "format is not supported for cloud models",
            "unsupported parameter: format",
            "unknown parameter: format",
            "unrecognized parameter: format"
        ]
        if formatParameterErrors.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .structuredOutput
        }
        return nil
    }
}

nonisolated struct CleanupChatOptions: Sendable {
    var structuredOutput = true

    mutating func adapt(to message: String) -> Bool {
        switch CleanupRequestAdaptation.unsupportedParameter(in: message) {
        case .structuredOutput where structuredOutput: structuredOutput = false; return true
        default: return false
        }
    }
}

/// Remember explicit protocol rejections, never transcript text or credentials.
/// A short lifetime lets a server upgrade regain structured output automatically.
actor CleanupSchemaSupport<Key: Hashable & Sendable> {
    private let lifetime: Duration
    private let capacity: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var rejected: [Key: ContinuousClock.Instant] = [:]

    init(lifetime: Duration = .seconds(300), capacity: Int = 8,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.now = now
    }

    func usesStructuredOutput(for key: Key) -> Bool {
        guard let time = rejected[key] else { return true }
        if time.duration(to: now()) < lifetime { return false }
        rejected[key] = nil
        return true
    }

    func recordUnsupportedSchema(for key: Key) {
        rejected[key] = now()
        if rejected.count > capacity, let oldest = rejected.min(by: { $0.value < $1.value })?.key {
            rejected[oldest] = nil
        }
    }

    func invalidate(_ key: Key) { rejected[key] = nil }
}

enum RemoteCleanupProcessing {
    static func process(
        text: String, instructions: String, vocabulary: [String], context: DictationPostProcessingContext?,
        contextLength: Int = 8_192, maximumCompletionTokens: Int? = nil,
        maximumConcurrentRequests: Int = 1,
        generate: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let fixedTokens = TranscriptCleanupPlan.estimatedTokens(instructions) + 512
        let chunks = try await TranscriptCleanupPlan.chunks(text) { candidate in
            let output = TranscriptCleanupPlan.outputReserve(inputTokens: TranscriptCleanupPlan.estimatedTokens(candidate))
            let request = remotePostProcessingRequestPrompt(text: candidate, vocabulary: vocabulary, context: context)
            return fixedTokens + TranscriptCleanupPlan.estimatedTokens(request) + output <= contextLength
                && (maximumCompletionTokens.map { output <= $0 } ?? true)
        }
        // Local model servers keep serial generation. Independent cloud
        // passages can overlap without changing partitions or their order.
        let limit = min(2, max(1, maximumConcurrentRequests))
        if limit == 1 || chunks.count <= 1 {
            var outputs: [String] = []
            for chunk in chunks {
                outputs.append(try await processChunk(chunk, generate: generate))
            }
            return outputs.joined()
        }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            var outputs = Array(repeating: "", count: chunks.count)
            func enqueueNext() {
                let index = nextIndex
                let chunk = chunks[index]
                nextIndex += 1
                group.addTask {
                    (index, try await processChunk(chunk, generate: generate))
                }
            }
            for _ in 0..<min(limit, chunks.count) { enqueueNext() }
            do {
                while let (index, output) = try await group.next() {
                    try Task.checkCancellation()
                    outputs[index] = output
                    if nextIndex < chunks.count { enqueueNext() }
                }
            } catch {
                group.cancelAll()
                throw error // No partial or reordered cleanup can escape.
            }
            return outputs.joined()
        }
    }

    private static func processChunk(_ chunk: TranscriptCleanupChunk,
                                     generate: @Sendable (String) async throws -> String) async throws -> String {
        try Task.checkCancellation()
        guard !chunk.text.isEmpty else { return chunk.original }
        let raw = try await generate(chunk.text)
        try Task.checkCancellation()
        return chunk.replacingText(with: cleanedRemotePostProcessingResponse(from: raw, originalText: chunk.text))
    }
}

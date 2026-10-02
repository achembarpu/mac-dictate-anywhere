#if arch(arm64)
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

nonisolated private struct S1MiniMLXTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

nonisolated private struct S1MiniMLXTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        S1MiniMLXTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Owns the native graph and tokenizer. The operation gate also covers awaits
/// during loading, so unload/prewarm/requests cannot overlap graph ownership.
actor S1MiniMLXInferenceEngine {
    static let shared = S1MiniMLXInferenceEngine()

    private var context: ModelContext?
    private var modelPath: String?
    private var warmed = false
    private var prefixTokens: [Int] = []
    private var prefixCache: [KVCache] = []
    private var usePrefix = true
    private var prefillStep = 256
    private var operationRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func generate(prompt: String, transcript: String, modelURL: URL) async throws -> String {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await loadIfNeeded(from: modelURL)
        guard let context else { throw S1MiniServiceError.modelLoadFailed }
        return try generate(prompt: prompt, transcript: transcript, context: context)
    }

    func transcriptChunks(_ text: String, modelURL: URL) async throws -> [String] {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await loadIfNeeded(from: modelURL)
        guard let context else { throw S1MiniServiceError.modelLoadFailed }
        return try S1MiniTranscriptChunker.chunks(text, maximumTokens: S1MiniModelSpec.maximumTranscriptTokens) {
            context.tokenizer.encode(text: $0, addSpecialTokens: false).count
        }
    }

    func prewarm(from modelURL: URL) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await loadIfNeeded(from: modelURL)
        guard !warmed, let context else { return }
        let trace = PerfTrace.begin("cleanup.prewarm")
        defer { trace.end() }
        // Exercise both short and batched prefill kernels plus autoregressive
        // decoding. Synthetic output/cache never becomes a user response.
        for text in ["Hello.", String(repeating: "This is a preparation sentence. ", count: 90)] {
            try Task.checkCancellation()
            let prompt = S1MiniPromptBuilder.prompt(transcript: text, styling: .semiFormal,
                                                   structure: .prose, context: "general")
            var iterator = try makeIterator(tokens: context.tokenizer.encode(text: prompt, addSpecialTokens: false),
                                            maximum: 1, context: context)
            _ = iterator.next()
            Stream().synchronize()
            try Task.checkCancellation()
        }
        warmed = true
    }

    func unload() async {
        await acquireOperation()
        defer { releaseOperation() }
        if context != nil {
            Stream().synchronize()
            context = nil
            Memory.clearCache()
        }
        modelPath = nil
        warmed = false
        prefixCache = []
        prefixTokens = []
    }

    private func loadIfNeeded(from url: URL) async throws {
        let path = url.standardizedFileURL.path
        if context != nil, modelPath == path { return }
        let trace = PerfTrace.begin("cleanup.modelLoad")
        defer { trace.end() }
        context = nil
        modelPath = nil
        warmed = false
        prefixCache = []
        prefixTokens = []
        // S1 is the only MLX application graph. Keep freed temporary arrays
        // bounded on smaller Macs rather than retaining a long-input high-water mark.
        Memory.cacheLimit = 64 * 1_024 * 1_024
        let loaded = try await loadModel(from: url, using: S1MiniMLXTokenizerLoader())
        try Task.checkCancellation()
        context = loaded
        modelPath = path
        prefixTokens = loaded.tokenizer.encode(text: S1MiniPromptBuilder.publicPrefix, addSpecialTokens: false)
        let cache = loaded.model.newCache(parameters: nil)
        _ = loaded.model(MLXArray(prefixTokens)[.newAxis], cache: cache)
        eval(cache.flatMap { $0.state })
        Stream().synchronize()
        prefixCache = cache
    }

    private func parameters(maximum: Int) -> GenerateParameters {
        // Author-trained greedy recipe; normal KV is much faster than quantized
        // KV for this graph in the native comparison. Do not rotate its context.
        GenerateParameters(maxTokens: maximum, temperature: 0, prefillStepSize: prefillStep)
    }

    private func generate(prompt: String, transcript: String, context: ModelContext) throws -> String {
        let trace = PerfTrace.begin("cleanup.generate")
        defer { trace.end() }
        let tokenizerTrace = PerfTrace.begin("cleanup.tokenize")
        let count = context.tokenizer.encode(text: transcript, addSpecialTokens: false).count
        let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
        tokenizerTrace.end()
        guard count <= S1MiniModelSpec.maximumTranscriptTokens else {
            throw S1MiniServiceError.transcriptTooLong(actual: count, maximum: S1MiniModelSpec.maximumTranscriptTokens)
        }
        try Task.checkCancellation()
        let maximum = Int(ceil(Double(count) * 1.3)) + 32
        let stops = Set([context.tokenizer.eosTokenId,
                         context.tokenizer.convertTokenToId("<|endoftext|>")].compactMap { $0 })
        guard stops.count == 2 else { throw S1MiniServiceError.invalidOutput }
        trace.recordCounts(["input_tokens": count, "prompt_tokens": tokens.count, "backend_mlx": 1])
        // Each iterator owns a new request cache. No chat history or unfinished
        // generation task outlives this synchronous actor-isolated operation.
        var completed = false
        defer {
            Stream().synchronize()
            if !completed { warmed = false }
        }
        let promptTrace = PerfTrace.begin("cleanup.promptEval")
        var iterator: TokenIterator
        do {
            defer { promptTrace.end() }
            iterator = try makeIterator(tokens: tokens, maximum: maximum + 1, context: context)
        }
        try Task.checkCancellation()
        let decodeTrace = PerfTrace.begin("cleanup.decode")
        defer { decodeTrace.end() }
        var output: [Int] = []
        while let token = iterator.next() {
            try Task.checkCancellation()
            if stops.contains(token) {
                completed = true
                trace.recordCounts(["output_tokens": output.count])
                return context.tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard output.count < maximum else { throw S1MiniServiceError.outputLimitReached }
            output.append(token)
        }
        throw S1MiniServiceError.outputLimitReached
    }

    private func makeIterator(tokens: [Int], maximum: Int, context: ModelContext) throws -> TokenIterator {
        let matchesPrefix = usePrefix && tokens.starts(with: prefixTokens)
        let requestTokens = matchesPrefix ? Array(tokens.dropFirst(prefixTokens.count)) : tokens
        // Copy only the fixed public system prompt. Token-ID equality guards
        // tokenizer boundaries; controls and transcripts always use a fresh suffix.
        return try TokenIterator(input: LMInput(tokens: MLXArray(requestTokens)), model: context.model,
            cache: matchesPrefix ? prefixCache.map { $0.copy() } : nil, parameters: parameters(maximum: maximum))
    }

    #if DEBUG || PIPELINE_BENCHMARK
    func configureForTesting(prefix: Bool, prefill: Int = 512) async {
        await acquireOperation()
        defer { releaseOperation() }
        usePrefix = prefix
        prefillStep = prefill
    }

    func stateForTesting() -> (loaded: Bool, warmed: Bool, prefixPositions: [Int]) {
        (context != nil, warmed, prefixCache.map { $0.offset })
    }
    #endif

    private func acquireOperation() async {
        if operationRunning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            operationRunning = true
        }
    }

    private func releaseOperation() {
        if waiters.isEmpty { operationRunning = false }
        else { waiters.removeFirst().resume() }
    }
}
#endif

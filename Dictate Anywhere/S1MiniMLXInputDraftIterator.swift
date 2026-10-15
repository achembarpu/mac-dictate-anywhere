#if arch(arm64)
import MLX
import MLXLMCommon

/// Verifies transcript-derived proposals with the unchanged greedy model.
/// The caller owns this iterator and its cache for one serialized request.
nonisolated struct S1MiniMLXInputDraftIterator {
    private let model: any LanguageModel
    private let cache: [KVCache]
    private let maximumTokens: Int
    private var draft: S1MiniInputDraft
    private var pending: [Int]
    private var pendingIndex = 0
    private var emitted = 0
    private var lastToken: Int?
    private var standard: TokenIterator?

    init(tokens: [Int], transcriptTokens: [Int], model: any LanguageModel,
         cache: [KVCache], maximumTokens: Int, prefillStepSize: Int) throws {
        self.model = model
        self.cache = cache
        self.maximumTokens = maximumTokens
        let parameters = GenerateParameters(maxTokens: maximumTokens, temperature: 0,
                                            prefillStepSize: prefillStepSize)
        self.draft = S1MiniInputDraft(tokens: transcriptTokens)
        self.pending = []
        guard !cache.isEmpty, cache.allSatisfy(\.isTrimmable) else {
            standard = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: model,
                                         cache: cache, parameters: parameters)
            return
        }
        let input = LMInput(tokens: MLXArray(tokens))
        let logits: MLXArray
        switch try model.prepare(input, cache: cache, windowSize: prefillStepSize) {
        case .tokens(let remaining):
            logits = model(remaining[text: .newAxis], cache: cache, state: nil).logits
        case .logits(let result):
            logits = result.logits
        }
        pending = [argMax(logits[0, -1, 0...], axis: -1).item(Int.self)]
    }

    mutating func next() throws -> Int? {
        guard emitted < maximumTokens else { return nil }
        if var standard {
            let token = standard.next()
            self.standard = standard
            if token != nil { emitted += 1 }
            return token
        }
        if pendingIndex == pending.count {
            guard let lastToken else { return nil }
            let proposals = draft.propose(maximumTokens: min(4, maximumTokens - emitted - 1))
            let predictions = argMax(model(MLXArray([lastToken] + proposals)[.newAxis],
                                           cache: cache)[0, 0..., 0...], axis: -1).asArray(Int.self)
            var accepted = 0
            while accepted < proposals.count && predictions[accepted] == proposals[accepted] {
                accepted += 1
            }
            let rejected = proposals.count - accepted
            for entry in cache {
                guard entry.trim(rejected) == rejected else { throw S1MiniServiceError.invalidOutput }
            }
            pending = Array(predictions.prefix(accepted + 1))
            pendingIndex = 0
        }
        let token = pending[pendingIndex]
        pendingIndex += 1
        emitted += 1
        lastToken = token
        draft.didEmit(token)
        return token
    }
}

nonisolated enum S1MiniMLXTokenIterator {
    case standard(TokenIterator)
    case inputDraft(S1MiniMLXInputDraftIterator)

    mutating func next() throws -> Int? {
        switch self {
        case .standard(var iterator):
            let token = iterator.next()
            self = .standard(iterator)
            return token
        case .inputDraft(var iterator):
            let token = try iterator.next()
            self = .inputDraft(iterator)
            return token
        }
    }
}
#endif

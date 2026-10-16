/// Request-local proposals from an earlier cleanup, then the styled raw input.
/// Both match only tokens already emitted by the authoritative greedy verifier.
nonisolated struct S1MiniVerifiedDraft {
    private var earlier: S1MiniInputDraft
    private var transcript: S1MiniInputDraft

    init(transcriptTokens: [Int], earlierOutputTokens: [Int]) {
        earlier = S1MiniInputDraft(tokens: earlierOutputTokens)
        transcript = S1MiniInputDraft(tokens: transcriptTokens)
    }

    mutating func didEmit(_ token: Int) {
        earlier.didEmit(token)
        transcript.didEmit(token)
    }

    mutating func propose(maximumTokens: Int) -> [Int] {
        let proposals = earlier.propose(maximumTokens: maximumTokens)
        return proposals.isEmpty ? transcript.propose(maximumTokens: maximumTokens) : proposals
    }
}

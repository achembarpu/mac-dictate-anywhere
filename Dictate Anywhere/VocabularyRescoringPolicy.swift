import FluidAudio

nonisolated enum VocabularyRescoringPolicy {
    /// SDK #702: scale the bonus by actual CTC token count so a short keyword
    /// cannot win on the flat boost alone. Disable acoustic rescue (#724): it
    /// dropped correct conjunctions and replaced Craig with an absent acronym.
    /// Constrained rescoring still recovers acoustically supported rare names.
    static let config = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        shortTermCbwTaperExponent: 2,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50,
        spotterRescueEnabled: false
    )
}

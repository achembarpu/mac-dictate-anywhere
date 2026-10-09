import Foundation

nonisolated enum CleanupResponseError: LocalizedError {
    case incompleteResponse
    case inputCannotFit

    var errorDescription: String? {
        switch self {
        case .incompleteResponse: return "The cleanup model did not finish its response. The original transcript is preserved."
        case .inputCannotFit: return "The cleanup instructions or an unbroken transcript segment exceed the model context. The original transcript is preserved."
        }
    }
}

/// Lossless input partitions. Separators belong to the input, not the model:
/// cleaning each part must not collapse paragraphs or join adjacent words.
nonisolated struct TranscriptCleanupChunk: Equatable, Sendable {
    let prefix: String
    let text: String
    let suffix: String

    init(_ raw: String) {
        let start = raw.firstIndex(where: { !$0.isWhitespace }) ?? raw.endIndex
        let end = raw.lastIndex(where: { !$0.isWhitespace }).map { raw.index(after: $0) } ?? start
        prefix = String(raw[..<start])
        text = String(raw[start..<end])
        suffix = String(raw[end...])
    }

    var original: String { prefix + text + suffix }
    func replacingText(with output: String) -> String { prefix + output + suffix }
}

nonisolated enum TranscriptCleanupPlan {
    /// Separate source paragraphs without assigning their separators to the
    /// model. Used for long transformations where repeated records must not
    /// be deduplicated or summarized together.
    static func paragraphs(_ text: String) -> [TranscriptCleanupChunk] {
        guard !text.isEmpty else { return [] }
        var result: [TranscriptCleanupChunk] = []
        var start = text.startIndex
        while let separator = text.range(of: "\n\n", range: start..<text.endIndex) {
            result.append(TranscriptCleanupChunk(String(text[start..<separator.upperBound])))
            start = separator.upperBound
        }
        if start < text.endIndex { result.append(TranscriptCleanupChunk(String(text[start...]))) }
        return result
    }

    /// The backend supplies its tokenizer/context test. Every selected boundary
    /// is rechecked because tokenization need not be monotonic at a suffix.
    static func chunks(
        _ text: String,
        fits: (String) async throws -> Bool
    ) async throws -> [TranscriptCleanupChunk] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        if characters.count <= 4_096 {
            try Task.checkCancellation()
            if try await fits(text) { return [TranscriptCleanupChunk(text)] }
        }
        var offset = 0
        var result: [TranscriptCleanupChunk] = []
        var probeHint = 512
        while offset < characters.count {
            try Task.checkCancellation()
            let remainingCount = characters.count - offset
            var measurements: [Int: Bool] = [:]
            func fitsLength(_ length: Int) async throws -> Bool {
                try Task.checkCancellation()
                if let cached = measurements[length] { return cached }
                let accepted = try await fits(String(characters[offset..<(offset + length)]))
                measurements[length] = accepted
                return accepted
            }
            // Find a bounded bracket before binary search. Never tokenize the
            // entire remaining recording just to discover another small chunk.
            var low = 0
            var high = min(probeHint, remainingCount)
            while try await fitsLength(high) {
                low = high
                if low == remainingCount { break }
                high = high > remainingCount / 2 ? remainingCount : high * 2
            }
            if low == remainingCount {
                result.append(TranscriptCleanupChunk(String(characters[offset...])))
                break
            }
            while low + 1 < high {
                let middle = low + (high - low) / 2
                if try await fitsLength(middle) { low = middle }
                else { high = middle }
            }
            probeHint = max(1, low)
            let boundaries = (1...max(1, low)).filter { end in
                let previous = characters[offset + end - 1]
                return previous.isWhitespace || "。！？".contains(previous)
            }
            let sentences = boundaries.filter { end in
                let previous = characters[offset + end - 1]
                return previous.isNewline || "。！？".contains(previous)
                    || (end > 1 && ".!?".contains(characters[offset + end - 2]))
            }
            var end = sentences.last(where: { $0 >= low / 2 }) ?? boundaries.last
            while let candidate = end {
                if try await fitsLength(candidate) { break }
                end = boundaries.last(where: { $0 < candidate })
            }
            guard let end, end > 0 else { throw CleanupResponseError.inputCannotFit }
            result.append(TranscriptCleanupChunk(String(characters[offset..<(offset + end)])))
            offset += end
        }
        return result
    }

    /// Providers without a tokenizer use a conservative byte budget. This is
    /// an estimate, not a token count; completion errors still preserve input.
    static func estimatedTokens(_ text: String) -> Int { text.utf8.count }

    static func outputReserve(inputTokens: Int) -> Int {
        max(128, Int(ceil(Double(inputTokens) * 1.3)) + 64)
    }
}

/// Shared OpenAI-compatible wire contract. Never accept a length-limited,
/// filtered, refused or tool-only response as a complete cleaned transcript.
nonisolated struct CleanupChatCompletion: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            struct Part: Decodable, Sendable { let text: String? }
            enum Content: Decodable, Sendable {
                case text(String)
                case parts([Part])
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) { self = .text(text) }
                    else { self = .parts(try container.decode([Part].self)) }
                }
                var text: String {
                    switch self {
                    case .text(let text): return text
                    case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
                    }
                }
            }
            let content: Content?
            let refusal: String?
        }
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    let choices: [Choice]

    func completeText() throws -> String {
        guard let choice = choices.first,
              choice.finishReason == nil || choice.finishReason == "stop",
              choice.message.refusal?.isEmpty != false,
              let text = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw CleanupResponseError.incompleteResponse }
        return text
    }
}

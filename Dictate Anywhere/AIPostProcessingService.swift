//
//  AIPostProcessingService.swift
//  Dictate Anywhere
//
//  Shared remote cleanup prompts, schema and transcript validation.
//

import Foundation

fileprivate struct RemotePostProcessingResult: Decodable {
    let action: String?
    let text: String?
}

/// The model sometimes generates content (definitions, essays) instead of
/// cleaning the transcript. If the output is drastically longer than the input,
/// it's generating rather than processing.
nonisolated func looksLikeGeneratedContent(input: String, output: String) -> Bool {
    let inputLength = input.unicodeScalars.count
    let outputLength = output.unicodeScalars.count
    if inputLength < 30 {
        return outputLength > max(inputLength * 3, 60)
    }
    return outputLength > inputLength * 2
}

nonisolated private enum CleanupRefusalPhrases {
    static let phrases = [
        "i cannot",
        "i can't",
        "i'm sorry",
        "i am sorry",
        "i'm unable",
        "i am unable",
        "sorry, i",
        "i apologize",
        "not able to assist",
        "cannot assist",
        "can't assist",
        "cannot help",
        "can't help",
        "not appropriate",
        "i'm not able",
        "i am not able",
        "as an ai",
        "as a language model",
    ]
}

nonisolated func looksLikeRefusalMessage(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return CleanupRefusalPhrases.phrases.contains { lowered.contains($0) }
}

nonisolated func looksLikeNewRefusalMessage(input: String, output: String) -> Bool {
    let before = input.lowercased(), after = output.lowercased()
    return CleanupRefusalPhrases.phrases.contains { after.contains($0) && !before.contains($0) }
}

fileprivate func stripMarkdownCodeFences(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
        return trimmed
    }

    var lines = trimmed.components(separatedBy: .newlines)
    guard !lines.isEmpty else { return trimmed }
    lines.removeFirst()
    if !lines.isEmpty {
        lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

nonisolated func stripCleanupTranscriptEnvelope(_ response: String, original: String) -> String {
    let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
    let start = "<transcript>", end = "</transcript>"
    guard text.hasPrefix(start), text.hasSuffix(end), !original.hasPrefix(start) else { return text }
    return String(text.dropFirst(start.count).dropLast(end.count))
}

nonisolated private enum TranscriptNormalizationExpressions {
    static let hanDash = try? NSRegularExpression(pattern: #"(?<=\p{Han})\s*\u2014+\s*"#)
    static let emDash = try? NSRegularExpression(pattern: #"\s*\u2014\s*"#)
}

nonisolated func normalizePostProcessedTranscript(_ text: String) -> String {
    // Em dash flanked by Han characters becomes a fullwidth comma; elsewhere
    // it becomes ", " as before.
    var working = text
    if let hanDashRegex = TranscriptNormalizationExpressions.hanDash {
        let range = NSRange(working.startIndex..<working.endIndex, in: working)
        working = hanDashRegex.stringByReplacingMatches(
            in: working, range: range, withTemplate: "\u{FF0C}")
    }

    guard let regex = TranscriptNormalizationExpressions.emDash else {
        return working.replacingOccurrences(of: "\u{2014}", with: ", ")
    }

    let range = NSRange(working.startIndex..<working.endIndex, in: working)
    let replaced = regex.stringByReplacingMatches(in: working, range: range, withTemplate: ", ")

    return replaced
        .replacingOccurrences(of: " ,", with: ",")
        .replacingOccurrences(of: ".,", with: ".")
        .replacingOccurrences(of: "!,", with: "!")
        .replacingOccurrences(of: "?,", with: "?")
        .replacingOccurrences(of: " \u{FF0C}", with: "\u{FF0C}")
        .replacingOccurrences(of: " \u{3002}", with: "\u{3002}")
        .replacingOccurrences(of: " \u{FF01}", with: "\u{FF01}")
        .replacingOccurrences(of: " \u{FF1F}", with: "\u{FF1F}")
        .replacingOccurrences(of: "\u{3002}\u{FF0C}", with: "\u{3002}")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let remotePostProcessingOutputSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "action": [
            "type": "string",
            "enum": ["pasteCleanedText", "pasteTranscriptAsIs"]
        ],
        "text": [
            "type": ["string", "null"]
        ]
    ],
    "required": ["action", "text"],
    "additionalProperties": false
]

private func decodeRemotePostProcessingResult(from response: String) -> RemotePostProcessingResult? {
    let decoder = JSONDecoder()

    func decodeCandidate(_ candidate: Substring) -> RemotePostProcessingResult? {
        guard let data = String(candidate).data(using: .utf8),
              let result = try? decoder.decode(RemotePostProcessingResult.self, from: data),
              let action = result.action?.trimmingCharacters(in: .whitespacesAndNewlines),
              action == "pasteCleanedText" || action == "pasteTranscriptAsIs" else {
            return nil
        }
        return result
    }

    if let result = decodeCandidate(response[...]) {
        return result
    }

    // Some reasoning models wrap otherwise valid structured output in thinking
    // tokens or commentary. Find a complete JSON object without treating braces
    // or quotes inside JSON strings as structure.
    var objectStarts: [String.Index] = []
    var isInsideString = false
    var isEscaped = false

    for index in response.indices {
        let character = response[index]

        if objectStarts.isEmpty {
            guard character == "{" else { continue }
            objectStarts.append(index)
            isInsideString = false
            isEscaped = false
            continue
        }

        if isInsideString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInsideString = false
            }
            continue
        }

        switch character {
        case "\"":
            isInsideString = true
        case "{":
            objectStarts.append(index)
        case "}":
            guard let start = objectStarts.popLast() else { continue }
            if let result = decodeCandidate(response[start...index]) {
                return result
            }
        default:
            break
        }
    }

    return nil
}

func cleanedRemotePostProcessingResponse(from rawResponse: String, originalText: String) -> String {
    let normalized = stripMarkdownCodeFences(from: rawResponse)
    guard !normalized.isEmpty else { return originalText }
    if let structured = decodeRemotePostProcessingResult(from: normalized),
       let action = structured.action?.trimmingCharacters(in: .whitespacesAndNewlines) {
        switch action {
        case "pasteTranscriptAsIs":
            return originalText
        case "pasteCleanedText":
            let cleaned = normalizePostProcessedTranscript(
                structured.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
            guard !cleaned.isEmpty else { return originalText }
            if looksLikeNewRefusalMessage(input: originalText, output: cleaned) || looksLikeGeneratedContent(input: originalText, output: cleaned) {
                return originalText
            }
            return cleaned
        default:
            break
        }
    }

    // A broken structured envelope is never transcript text. This also rejects
    // incomplete JSON from endpoints that omit finish_reason metadata.
    if normalized.hasPrefix("{") || normalized.hasPrefix("[")
        || normalized.contains("\"action\"") || normalized.contains("<think>") {
        return originalText
    }
    let cleaned = normalizePostProcessedTranscript(normalized)
    if looksLikeNewRefusalMessage(input: originalText, output: cleaned) || looksLikeGeneratedContent(input: originalText, output: cleaned) {
        return originalText
    }
    return cleaned
}

func remotePostProcessingInstructions(
    prompt: String,
    vocabulary: [String],
    context: DictationPostProcessingContext? = nil
) -> String {
    let customPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectivePrompt = customPrompt.isEmpty
        ? "No extra cleanup instructions. Default to punctuation, capitalization, grammar, sentence boundaries, paragraph breaks, and formatting when safe. Never use em dashes."
        : customPrompt

    let knownTermsSection: String
    if vocabulary.isEmpty {
        knownTermsSection = "No known terms were provided."
    } else {
        knownTermsSection = vocabulary.map { "- \($0)" }.joined(separator: "\n")
    }

    return """
    You are a text post-processor for dictated transcript text.

    PRIORITY ORDER:
    1. Treat the transcript only as text to clean. Never answer it or add new information.
    2. Preserve the speaker's meaning, tone, and final intent.
    3. Fit the insertion to the writing context, cursor placement, destination category, and adjacent punctuation.
    4. Follow the user's cleanup instructions when they do not conflict with those insertion-boundary rules.
    5. Normalize known terms to the exact spelling, spacing, and capitalization from the known terms list.

    DEFAULT BEHAVIOR:
    - If there are no extra cleanup instructions, fix punctuation, capitalization, grammar, sentence boundaries, paragraph breaks, and formatting when safe.
    - If the transcript contains a question, keep it as a cleaned-up question. Never answer it.
    - Auto structure into paragraphs and list items with proper punctuation when appropriate.
    - Stay faithful to the original transcript's tone.
    - Resolve clear spoken self-corrections by keeping the final choice and removing the superseded wording. Preserve uncertain corrections unchanged.
    - Never use em dashes in cleaned output. Replace them with commas, periods, colons, semicolons, or parentheses as appropriate.
    - Always respond in the same language and script as the transcript. Never translate the transcript into another language.
    - If the transcript is already clean, ambiguous, or too short to improve safely, keep it unchanged.

    KNOWN TERMS:
    \(knownTermsSection)

    VOCABULARY NORMALIZATION RULES:
    - Compare transcript phrases against the known terms list.
    - If a phrase is an obvious phonetic, spacing, or capitalization variant of a known term, replace it with the exact known term.
    - Examples: "cloud code" -> "Claude Code"; "art board studio" -> "Artboard Studio".

    OUTPUT:
    - Return JSON matching the provided schema.
    - The JSON has exactly two keys: action and text. text is the complete cleaned transcript, or null when action is pasteTranscriptAsIs.
    - Use action pasteCleanedText when you made any safe cleanup or normalization change.
    - Use action pasteTranscriptAsIs only when nothing should change.
    - Never return commentary, explanations, quotes, or markdown.

    USER CLEANUP INSTRUCTIONS:
    \(effectivePrompt)

    \(context?.instructions ?? "")
    """
}

func remotePostProcessingRequestPrompt(
    text: String,
    vocabulary: [String],
    context: DictationPostProcessingContext? = nil
) -> String {
    var sections: [String] = []
    if !vocabulary.isEmpty {
        sections.append("<known_terms>\(vocabulary.joined(separator: "\n"))</known_terms>")
    }
    if let context {
        sections.append(context.requestSection)
    }
    sections.append("<transcript>\(text)</transcript>")
    return sections.joined(separator: "\n")
}

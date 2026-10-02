import Foundation

/// A conservative preservation gate for long model transformations, not a
/// semantic verifier. A rejected passage keeps its complete original text.
nonisolated enum TranscriptCleanupIntegrity {
    private static let numericLiteral = try! NSRegularExpression(pattern: #"\d+"#)
    private static let commaGrouping = try! NSRegularExpression(pattern: #",(?=\d{3}(?:\D|$))"#)

    static func preservesNumericLiterals(from source: String, in output: String) -> Bool {
        func counts(_ text: String) -> [String: Int] {
            let folded = text.folding(options: .widthInsensitive, locale: nil)
            // Accept common comma thousands formatting without treating a
            // decimal point as a grouping separator or dropping digit groups.
            let normalized = commaGrouping.stringByReplacingMatches(in: folded,
                range: NSRange(folded.startIndex..<folded.endIndex, in: folded), withTemplate: "")
            var counts: [String: Int] = [:]
            for match in numericLiteral.matches(in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)) {
                guard let range = Range(match.range, in: normalized) else { continue }
                counts[String(normalized[range]), default: 0] += 1
            }
            return counts
        }
        let actual = counts(output)
        return counts(source).allSatisfy { actual[$0.key, default: 0] >= $0.value }
    }
}

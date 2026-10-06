import Foundation

/// S1's quantized and full-precision variants can drop a numeric minus sign
/// while formatting money. Retain the original instead of changing its meaning.
nonisolated enum S1MiniOutputSafety {
    private static let signedNumber = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:minus\s+|negative\s+|[-−]\s*)[$€£]?\s*([0-9]+(?:[.,][0-9]+)?)"#
    )

    static func removesNumericSign(input: String, output: String) -> Bool {
        let expected = negativeNumbers(in: input)
        guard !expected.isEmpty else { return false }
        var actual = negativeNumbers(in: output)
        var unmatched: [String] = []
        // Reserve exact matches first so a decimal expansion cannot consume
        // an occurrence needed by another input value.
        for value in expected {
            if let index = actual.firstIndex(of: value) {
                actual.remove(at: index)
            } else {
                unmatched.append(value)
            }
        }
        for value in unmatched {
            // "minus 42 dollars and 75 cents" may legitimately become "-$42.75".
            guard let index = actual.firstIndex(where: { $0.hasPrefix(value + ".") }) else {
                return true
            }
            actual.remove(at: index)
        }
        return false
    }

    private static func negativeNumbers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return signedNumber.matches(in: text, range: range).compactMap { match in
            guard let number = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[number]).replacingOccurrences(of: ",", with: "")
        }
    }
}

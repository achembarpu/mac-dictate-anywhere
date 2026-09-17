import Foundation

/// Formatting inferred only at an empty list prefix. List content elsewhere in
/// the field must not change the behavior of ordinary sentence insertions.
struct DictationListInsertion: Equatable, Sendable {
    enum Capitalization: String, Sendable {
        case uppercase, lowercase
    }

    let capitalization: Capitalization?
    let omitsFinalPeriod: Bool
    let needsSpaceAfterMarker: Bool
    var isEmptyStructuralItem = false
    var literalMarker: String? = nil
    var literalIndent = ""
    var requiredFinalPeriod: Character? = nil

    /// Rich editors supply their own markers. Plain text needs the captured
    /// marker repeated, with successive ordinals for numbered items.
    func continuationPrefix(itemOffset: Int) -> String {
        guard let literalMarker else { return "" }
        if let number = Int(literalMarker.dropLast()), let delimiter = literalMarker.last {
            return literalIndent + String(number + itemOffset) + String(delimiter) + " "
        }
        return literalIndent + literalMarker + " "
    }

    var instructions: String {
        var lines = [
            "- The cursor is at the start of a list item, not mid-sentence. Return only item text, without bullets, numbers, or leading whitespace. Put distinct enumerated items on separate lines; keep compound names/descriptions together. These list rules override generic writing-style rules."
        ]
        if let capitalization {
            lines.append("- Match nearby list items: start an ordinary word with \(capitalization.rawValue). Preserve names, acronyms, and brand capitalization.")
        }
        if omitsFinalPeriod {
            lines.append("- Nearby list items omit final periods. Do not add a final period to this item.")
        }
        return lines.joined(separator: "\n")
    }

    static func infer(before: String?, after: String?) -> Self? {
        guard let before else { return nil }
        let beforeLines = before.components(separatedBy: .newlines)
        guard let currentLine = beforeLines.last,
              let current = parse(currentLine), current.body.isEmpty else { return nil }

        let afterLines = (after ?? "").components(separatedBy: .newlines)
        // Only immediate nonempty neighbors at the same indentation and marker
        // style can establish a convention; don't borrow it from another list.
        let previous = beforeLines.dropLast().reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let next = afterLines.dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let neighbors = [previous, next].compactMap { line -> String? in
            guard let line, let item = parse(line), !item.body.isEmpty,
                  item.indent == current.indent, item.kind == current.kind else { return nil }
            return item.body
        }
        var result = matchingNeighbors(
            neighbors,
            needsSpaceAfterMarker: !current.isNativeBullet && currentLine.last?.isWhitespace == false
        )
        result.literalMarker = current.marker
        result.literalIndent = current.indent
        return result
    }

    /// Rich-text AX values often omit the rendered bullets. Only a confirmed
    /// empty structural list item may use this path; blank prose isn't a list.
    nonisolated static func emptyStructuralItem(
        itemText: String,
        previousItemText: String?,
        nextItemText: String?
    ) -> Self? {
        let current = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || parse(current)?.body.isEmpty == true else { return nil }
        let neighbors = [previousItemText, nextItemText].compactMap { text -> String? in
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = parse(trimmed)?.body ?? trimmed
            return body.isEmpty ? nil : body
        }
        var result = matchingNeighbors(neighbors, needsSpaceAfterMarker: false)
        result.isEmptyStructuralItem = true
        return result
    }

    private nonisolated static func matchingNeighbors(_ neighbors: [String], needsSpaceAfterMarker: Bool) -> Self {
        let cases = neighbors.compactMap { text -> Capitalization? in
            guard let first = text.first(where: \.isLetter) else { return nil }
            return first.isUppercase ? .uppercase : first.isLowercase ? .lowercase : nil
        }
        let capitalization = cases.first.flatMap { candidate in
            cases.allSatisfy { $0 == candidate } ? candidate : nil
        }
        let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        let omitsPeriod = !neighbors.isEmpty && neighbors.allSatisfy { item in
            !terminalPunctuation.contains(item.last!)
        }
        var result = Self(
            capitalization: capitalization,
            omitsFinalPeriod: omitsPeriod,
            needsSpaceAfterMarker: needsSpaceAfterMarker
        )
        if let period = neighbors.first?.last, period == "." || period == "。",
           neighbors.allSatisfy({ $0.last == period }) {
            result.requiredFinalPeriod = period
        }
        return result
    }

    private struct Item: Sendable {
        let indent: String
        let kind: String
        let marker: String
        let body: String
        let isNativeBullet: Bool
    }

    private nonisolated static func parse(_ line: String) -> Item? {
        // Native AX bullets can have no separator at all. Markdown bullets and
        // numbered markers require whitespace (or the end of an empty prefix).
        let pattern = #"^(\h*)(?:([•◦▪‣⁃●○∙])\h*|([-+*]|[0-9]{1,4}[.)])(?:\h+|$))(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let value = line as NSString
        let nativeRange = match.range(at: 2)
        let native = nativeRange.location != NSNotFound
        let marker = value.substring(with: match.range(at: native ? 2 : 3))
        let kind = marker.first?.isNumber == true ? "numbered-\(marker.last!)" : marker
        return Item(
            indent: value.substring(with: match.range(at: 1)), kind: kind, marker: marker,
            body: value.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces),
            isNativeBullet: native
        )
    }
}

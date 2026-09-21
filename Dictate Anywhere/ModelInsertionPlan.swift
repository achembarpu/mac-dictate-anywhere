import Foundation

/// A polished model response owns wording and boundary spaces together. Keeping
/// these separate from the displayed transcript avoids guessing spaces again
/// from an accessibility string that may have flattened rich-text structure.
struct ModelInsertionPlan: Equatable, Sendable {
    let text: String
    let spaceBefore: Bool
    let spaceAfter: Bool

    private struct Response: Decodable {
        let text: String?
        let items: [String]?
        let spaceBefore: Bool
        let spaceAfter: Bool

        enum CodingKeys: String, CodingKey {
            case text, items
            case spaceBefore = "space_before"
            case spaceAfter = "space_after"
        }
    }

    var insertionText: String {
        (spaceBefore ? " " : "") + text.trimmingCharacters(in: .whitespacesAndNewlines) + (spaceAfter ? " " : "")
    }

    static func decode(_ response: String, allowsEnumeratedItems: Bool = false) -> Self? {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let newline = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: newline)...].dropLast(3))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else { return nil }
        let text: String
        if let items = decoded.items {
            // Only a confirmed list/inline-series destination may interpret
            // semantic items. Never turn unexpected prose fragments into lines.
            guard allowsEnumeratedItems, decoded.text == nil, !items.isEmpty else { return nil }
            let trimmed = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) }) else { return nil }
            text = trimmed.joined(separator: "\n")
        } else {
            guard let value = decoded.text else { return nil }
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        return Self(text: text, spaceBefore: decoded.spaceBefore, spaceAfter: decoded.spaceAfter)
    }
}

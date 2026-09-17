import Foundation

/// A polished model response owns wording and boundary spaces together. Keeping
/// these separate from the displayed transcript avoids guessing spaces again
/// from an accessibility string that may have flattened rich-text structure.
struct ModelInsertionPlan: Decodable, Equatable, Sendable {
    let text: String
    let spaceBefore: Bool
    let spaceAfter: Bool

    enum CodingKeys: String, CodingKey {
        case text
        case spaceBefore = "space_before"
        case spaceAfter = "space_after"
        case items
    }

    var insertionText: String {
        (spaceBefore ? " " : "") + text.trimmingCharacters(in: .whitespacesAndNewlines) + (spaceAfter ? " " : "")
    }

    static func decode(_ response: String) -> Self? {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let newline = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: newline)...].dropLast(3))
        }
        guard let plan = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              !plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return plan
    }
}

extension ModelInsertionPlan {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spaceBefore = try values.decode(Bool.self, forKey: .spaceBefore)
        spaceAfter = try values.decode(Bool.self, forKey: .spaceAfter)
        if let items = try values.decodeIfPresent([String].self, forKey: .items), !items.isEmpty {
            let trimmed = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed.allSatisfy({ !$0.isEmpty }) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: values,
                    debugDescription: "Each enumerated item must contain one nonempty item.")
            }
            text = trimmed.joined(separator: "\n")
        } else {
            text = try values.decode(String.self, forKey: .text)
        }
    }
}

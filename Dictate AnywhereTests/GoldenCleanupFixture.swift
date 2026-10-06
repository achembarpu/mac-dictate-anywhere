import Foundation
import XCTest
@testable import Dictate_Anywhere

struct GoldenCleanupFixture: Decodable {
    let id: String
    let language: String
    let input: String
    let reference: String
    let vocabulary: [String]?
    let required: [[String]]
    let requiredFacts: [[String]]?
    let forbidden: [String]
    let question: Bool?

    static func all() throws -> [Self] {
        let url = try GoldenSpeechFixture.resource("cleanup-golden-manifest.json")
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    static func s1Stress() throws -> [Self] {
        let url = try GoldenSpeechFixture.resource("s1-cleanup-stress-manifest.json")
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    func violations(in output: String) -> [String] {
        let normalized = output.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        var issues = required.compactMap { alternatives -> String? in
            alternatives.contains { normalized.contains($0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)) }
                ? nil : "missing: " + alternatives.joined(separator: " / ")
        }
        issues += forbidden.filter { normalized.contains($0.lowercased()) }.map { "invented or unresolved: " + $0 }
        if question == true, !output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            issues.append("question lost its question mark")
        }
        if output.isEmpty { issues.append("empty output") }
        return issues
    }

    func lostFacts(in output: String) -> [String] {
        let normalized = output.lowercased()
        return (requiredFacts ?? required).compactMap { alternatives in
            alternatives.contains { normalized.contains($0.lowercased()) } ? nil : alternatives.joined(separator: " / ")
        }
    }
}

final class GoldenCleanupFixtureTests: XCTestCase {
    func testAuthoredReferencesMeetTheirOwnContentRequirements() throws {
        let fixtures = try GoldenCleanupFixture.all() + GoldenCleanupFixture.s1Stress()
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count)
        XCTAssertGreaterThanOrEqual(Set(fixtures.map(\.language)).count, 4)
        for fixture in fixtures {
            XCTAssertTrue(fixture.violations(in: fixture.reference).isEmpty, fixture.id)
        }
    }

    func testChecksDetectLostEndingNegationAndAnsweredQuestion() throws {
        let fixtures = try GoldenCleanupFixture.all()
        let long = try XCTUnwrap(fixtures.first { $0.id == "long-complete-ending" })
        XCTAssertFalse(long.violations(in: String(long.reference.prefix(1_000))).isEmpty)
        let numbers = try XCTUnwrap(fixtures.first { $0.id == "numbers-negation" })
        XCTAssertFalse(numbers.violations(in: numbers.reference.replacingOccurrences(of: "Do not", with: "Do")).isEmpty)
        let question = try XCTUnwrap(fixtures.first { $0.id == "question-not-answer" })
        XCTAssertFalse(question.violations(in: "Paris is the capital of France.").isEmpty)
    }
}

import XCTest
import AVFoundation
import CryptoKit
@testable import Dictate_Anywhere

final class GoldenSpeechFixtureTests: XCTestCase {
    func testBundledHumanReferencesHaveMatchingHashesAndAudioFormat() throws {
        let fixtures = try GoldenSpeechFixture.all()
        XCTAssertGreaterThanOrEqual(fixtures.count, 14)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count)
        XCTAssertEqual(Set(fixtures.map(\.language)), ["en", "zh", "nl", "de", "zh-en"])
        for fixture in fixtures {
            let audio = try fixture.audioURL
            let reference = try GoldenSpeechFixture.resource(fixture.reference)
            let file = try AVAudioFile(forReading: audio)
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000, fixture.id)
            XCTAssertEqual(file.processingFormat.channelCount, 1, fixture.id)
            XCTAssertEqual(Int(file.length), fixture.sampleCount, fixture.id)
            XCTAssertEqual(try hash(audio), fixture.audioSHA256, fixture.id)
            XCTAssertEqual(try hash(reference), fixture.referenceSHA256, fixture.id)
            XCTAssertFalse(try fixture.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(fixture.source.isEmpty)
            XCTAssertFalse(fixture.sourceId.isEmpty)
            XCTAssertTrue(fixture.tags.contains("human"), fixture.id)
        }
    }

    func testReferenceMetricPreservesNumbersAndBilingualWords() {
        XCTAssertEqual(GoldenSpeechFixture.errorRate(reference: "我去 Apple Park。", hypothesis: "我去 apple park!", metric: .cer), 0)
        XCTAssertGreaterThan(GoldenSpeechFixture.errorRate(reference: "三点", hypothesis: "四点", metric: .cer), 0)
        XCTAssertGreaterThan(GoldenSpeechFixture.errorRate(reference: "at 12", hypothesis: "at 13", metric: .wer), 0)
    }

    func testGoldenLanguagesMatchModelCoverage() throws {
        let fixtures = try GoldenSpeechFixture.all()
        let chinese = try XCTUnwrap(fixtures.first { $0.language == "zh" })
        XCTAssertTrue(chinese.supports(.senseVoice))
        XCTAssertTrue(chinese.supports(.nemotronMultilingual))
        XCTAssertFalse(chinese.supports(.multilingual))
        XCTAssertFalse(chinese.supports(.englishOnly))
        XCTAssertTrue(try XCTUnwrap(fixtures.first { $0.language == "nl" }).supports(.multilingual))
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

import XCTest
import FluidAudio
@testable import Dictate_Anywhere

final class BatchTranscriptionPolicyTests: XCTestCase {
    func testScriptHintsUseOnlyTheMultilingualTDTModels() {
        for model in ParakeetModelChoice.allCases {
            let language = BatchTranscriptionPolicy.scriptLanguage(for: model, selected: .polish)
            if model == .multilingual || model == .multilingualUltra {
                XCTAssertEqual(language, .polish)
            } else { XCTAssertNil(language, model.rawValue) }
        }
        for language in [SupportedLanguage.greek, .russian, .ukrainian, .bulgarian] {
            XCTAssertNil(BatchTranscriptionPolicy.scriptLanguage(for: .multilingual, selected: language))
            XCTAssertNil(BatchTranscriptionPolicy.scriptLanguage(for: .multilingualUltra, selected: language))
        }
        XCTAssertNil(BatchTranscriptionPolicy.scriptLanguage(for: .multilingual, selected: .norwegian))
        XCTAssertNil(BatchTranscriptionPolicy.scriptLanguage(for: .multilingual, selected: .chinese))
    }

    func testQuietSpeechQualificationSurvivesTrailingSilenceButExpiresForPreviews() {
        var presence = BatchSpeechPresence()
        XCTAssertFalse(presence.hasSpeech)
        XCTAssertFalse(presence.hasRecentSpeech(at: 8_000))
        presence.observe(isSpeech: true, at: 8_000)
        XCTAssertTrue(presence.hasSpeech)
        XCTAssertTrue(presence.hasRecentSpeech(at: 16_000))
        presence.observe(isSpeech: false, at: 32_000)
        XCTAssertTrue(presence.hasSpeech, "Final quiet speech remains eligible after a pause")
        XCTAssertFalse(presence.hasRecentSpeech(at: 32_000), "Silence must not keep scheduling previews")
    }

    func testFirstPreviewIsFastAndLaterPreviewsRequireNewAudio() {
        XCTAssertFalse(BatchTranscriptionPolicy.shouldPreview(totalSamples: 7_999, lastPreviewSamples: 0, hasVisibleText: false, model: .multilingual))
        XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(totalSamples: 8_000, lastPreviewSamples: 0, hasVisibleText: false, model: .multilingual))
        XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(totalSamples: 16_000, lastPreviewSamples: 8_000, hasVisibleText: false, model: .multilingual), "Empty guesses must not slow first visible words")
        XCTAssertFalse(BatchTranscriptionPolicy.shouldPreview(totalSamples: 23_999, lastPreviewSamples: 8_000, hasVisibleText: true, model: .multilingual))
        XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(totalSamples: 24_000, lastPreviewSamples: 8_000, hasVisibleText: true, model: .multilingual))
    }

    func testSustainedTDTPreviewsReduceWorkWithoutDelayingFirstText() {
        for model in ParakeetModelChoice.allCases {
            XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(
                totalSamples: 127_999, lastPreviewSamples: 111_999,
                hasVisibleText: true, model: model), "Short recordings retain one-second feedback")
            XCTAssertEqual(BatchTranscriptionPolicy.shouldPreview(
                totalSamples: 128_000, lastPreviewSamples: 112_000,
                hasVisibleText: true, model: model), ![ParakeetModelChoice.englishOnly, .multilingual, .multilingualUltra, .compactEnglish].contains(model))
            XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(
                totalSamples: 144_000, lastPreviewSamples: 112_000,
                hasVisibleText: true, model: model))
            XCTAssertTrue(BatchTranscriptionPolicy.shouldPreview(
                totalSamples: 160_000, lastPreviewSamples: 152_000,
                hasVisibleText: false, model: model), "Empty guesses keep retrying quickly")
            XCTAssertFalse(BatchTranscriptionPolicy.shouldPreview(
                totalSamples: 160_000, lastPreviewSamples: 160_000,
                hasVisibleText: true, model: model), "Inference never schedules a stale guess")
        }
    }

    func testFinalCorrectionWinsEvenWhenItRemovesWords() {
        XCTAssertEqual(BatchTranscriptionPolicy.finalTranscript(" meet tomorrow ", fallback: "meet meet tomorrow"), "meet tomorrow")
        XCTAssertEqual(BatchTranscriptionPolicy.finalTranscript("", fallback: "unfinished guess"), "unfinished guess")
    }

    func testShortSenseVoiceSegmentsAreMergedUntilTarget() {
        var boundaries = SenseVoicePauseBoundaries()
        boundaries.recordPause(at: 4 * 16_000)
        boundaries.recordPause(at: 12 * 16_000)
        XCTAssertNil(boundaries.nextBoundary(start: 0, end: 14 * 16_000))
        XCTAssertEqual(boundaries.nextBoundary(start: 0, end: 15 * 16_000), 12 * 16_000)
        boundaries.didCommit(through: 12 * 16_000)
        XCTAssertTrue(boundaries.pauses.isEmpty)
    }

    func testSenseVoiceWaitsForPauseAfterTargetAndCapsContinuousSpeech() {
        var boundaries = SenseVoicePauseBoundaries()
        XCTAssertNil(boundaries.nextBoundary(start: 0, end: 29 * 16_000))
        boundaries.recordPause(at: 24 * 16_000)
        XCTAssertEqual(boundaries.nextBoundary(start: 0, end: 25 * 16_000), 24 * 16_000)
        boundaries.didCommit(through: 24 * 16_000)
        XCTAssertEqual(boundaries.nextBoundary(start: 24 * 16_000, end: 60 * 16_000), 54 * 16_000)
    }

    func testSenseVoiceSegmentsCoverEverySampleOnceIncludingShortTail() {
        var boundaries = SenseVoicePauseBoundaries()
        for second in [7, 14, 32, 49] { boundaries.recordPause(at: second * 16_000) }
        let end = 61 * 16_000 + 37
        var start = 0
        var ranges: [Range<Int>] = []
        while let boundary = boundaries.nextBoundary(start: start, end: end) {
            ranges.append(start..<boundary)
            boundaries.didCommit(through: boundary)
            start = boundary
        }
        ranges.append(start..<end)
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, end)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 30 * 16_000 })
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, end)
        for pair in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
    }

    func testPreviewUsesAudioTimesAndPreservesRepeatedWords() {
        var timeline = BatchPreviewTimeline()
        timeline.update([token(" go", at: 1), token(" go", at: 2), token(" yester", at: 3)])
        let result = ASRResult(text: "go tomorrow", confidence: 1, duration: 4, processingTime: 0,
                               tokenTimings: [token(" go", at: 0), token(" tomorrow", at: 1)])
        XCTAssertEqual(timeline.preview(result, startingAt: 2 * 16_000), "go go tomorrow")
        timeline.update([token(" yesterday", at: 3), token(" today", at: 4)])
        XCTAssertEqual(timeline.words.map(\.word), ["go", "go", "yesterday", "today"])
    }

    func testBatchOnlyPreviewKeepsPrefixWhenAudioWindowMoves() {
        var timeline = BatchPreviewTimeline()
        let first = ASRResult(text: "go go yesterday", confidence: 1, duration: 4, processingTime: 0,
                              tokenTimings: [token(" go", at: 1), token(" go", at: 2), token(" yesterday", at: 3)])
        XCTAssertEqual(timeline.recordPreview(first, startingAt: 0), "go go yesterday")
        let next = ASRResult(text: "go tomorrow", confidence: 1, duration: 3, processingTime: 0,
                             tokenTimings: [token(" go", at: 0), token(" tomorrow", at: 1)])
        XCTAssertEqual(timeline.recordPreview(next, startingAt: 2 * 16_000), "go go tomorrow")
    }

    private func token(_ text: String, at time: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 1, startTime: time, endTime: time + 0.25, confidence: 1)
    }
}

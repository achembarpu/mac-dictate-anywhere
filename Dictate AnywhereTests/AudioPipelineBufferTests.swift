import XCTest
@testable import Dictate_Anywhere

@MainActor
final class AudioPipelineBufferTests: XCTestCase {
    func testCaptureRetainsOriginalAudioOnlyForDecodersThatConsumeIt() {
        let block = [Float](repeating: 0.125, count: 16_000)
        for model in ParakeetModelChoice.allCases {
            let engine = ParakeetEngine()
            for _ in 0..<60 { engine.captureSamplesForTesting(block, model: model) }
            let counts = engine.capturedSampleCountsForTesting
            XCTAssertEqual(counts.total, 960_000, model.rawValue)
            XCTAssertEqual(counts.pending, counts.total, "All audio still reaches recognition")
            XCTAssertEqual(counts.retained, model == .englishOnly ? counts.total : 0,
                "Only v2 needs original audio without vocabulary")
        }
    }

    func testVocabularyKeepsOriginalAudioOnlyForSupportedBatchModels() {
        let block = [Float](repeating: 0.125, count: 16_000)
        for model in ParakeetModelChoice.allCases {
            let engine = ParakeetEngine()
            for _ in 0..<60 { engine.captureSamplesForTesting(block, model: model, vocabularyTerms: ["Zephyr"]) }
            XCTAssertEqual(engine.capturedSampleCountsForTesting.retained,
                           [.multilingual, .multilingualUltra, .englishOnly, .compactEnglish].contains(model) ? 960_000 : 0,
                           model.rawValue)
        }
    }

    func testOversizedInputKeepsPendingAudioBoundedButPreservesBatchFinalAudio() {
        let engine = ParakeetEngine()
        engine.captureSamplesForTesting([Float](repeating: 0.125, count: 180 * 16_000), model: .englishOnly)
        let counts = engine.capturedSampleCountsForTesting
        XCTAssertEqual(counts.pending, 120 * 16_000)
        XCTAssertEqual(counts.retained, 180 * 16_000)
        XCTAssertEqual(counts.total, counts.retained)
    }

    func testVolumeQualificationPreservesRMSAndSparsePeakThresholds() {
        let engine = ParakeetEngine()
        XCTAssertFalse(engine.batchReplayHasSignificantAudioForTesting([]))
        XCTAssertFalse(engine.batchReplayHasSignificantAudioForTesting([Float](repeating: 0, count: 8_000)))
        XCTAssertTrue(engine.batchReplayHasSignificantAudioForTesting([Float](repeating: -0.01, count: 8_000)))
        var sparse = [Float](repeating: 0, count: 8_000)
        sparse.replaceSubrange(0..<119, with: repeatElement(Float(0.02), count: 119))
        XCTAssertFalse(engine.batchReplayHasSignificantAudioForTesting(sparse))
        sparse[119] = -0.02
        XCTAssertTrue(engine.batchReplayHasSignificantAudioForTesting(sparse))
        let recording = sparse + [Float](repeating: 0, count: 24_000)
        XCTAssertFalse(engine.batchReplayHasSignificantAudioForTesting(recording), "Preview uses recent audio")
        XCTAssertTrue(engine.batchReplayContainsSignificantAudioForTesting(recording), "Final speech survives a quiet ending")
    }
}

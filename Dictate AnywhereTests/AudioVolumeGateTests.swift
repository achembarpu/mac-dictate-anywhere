import XCTest
@testable import Dictate_Anywhere

final class AudioVolumeGateTests: XCTestCase {
    private func originalRecordingScan(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        for start in stride(from: 0, to: samples.count, by: 4_000) {
            let end = min(start + 8_000, samples.count)
            if AudioVolumeGate.qualifies(samples[start..<end]) { return true }
            if end == samples.count { break }
        }
        return false
    }

    func testIncrementalWindowsAndTailMatchRecordingScanAtEveryAppend() {
        for length in [0, 1, 3_999, 4_000, 7_999, 8_000, 8_001, 11_999, 12_000, 12_001, 24_101] {
            for placement in [0, max(0, length / 2 - 60), max(0, length - 119)] {
                var recording = [Float](repeating: 0, count: length)
                for index in placement..<min(length, placement + 119) { recording[index] = index.isMultiple(of: 2) ? 0.02 : -0.02 }
                for block in [1, 511, 4_096, 16_000] {
                    var gate = AudioVolumeGate()
                    for start in stride(from: 0, to: length, by: block) {
                        let end = min(start + block, length)
                        gate.append(Array(recording[start..<end]))
                        if block > 1 || end.isMultiple(of: 4_000) || end == length {
                            XCTAssertEqual(gate.containsSignificantAudio, originalRecordingScan(Array(recording[..<end])),
                                           "length=\(length) end=\(end) block=\(block) placement=\(placement)")
                        }
                    }
                    XCTAssertEqual(gate.containsSignificantAudio, originalRecordingScan(recording))
                }
            }
        }
    }

    func testExactFullWindowDoesNotQualifyItsShorterSparseSuffix() {
        var samples = [Float](repeating: 0, count: 8_000)
        samples.replaceSubrange(7_900..<8_000, with: repeatElement(Float(0.02), count: 100))
        var gate = AudioVolumeGate()
        gate.append(samples)
        XCTAssertFalse(gate.containsSignificantAudio)
        gate.append([0])
        XCTAssertTrue(gate.containsSignificantAudio, "The new partial window legitimately has a higher voiced ratio")
    }

    func testHourOfSilenceKeepsOnlyVolumeWindowsAndRecentPreviewAudio() {
        var gate = AudioVolumeGate()
        let block = [Float](repeating: 0, count: 16_000)
        for _ in 0..<3_600 {
            gate.append(block)
            XCTAssertLessThanOrEqual(gate.retainedSampleCount, 16_000)
        }
        XCTAssertFalse(gate.containsSignificantAudio)
        XCTAssertEqual(gate.recentSamples.count, 8_000)
    }

    func testEarlySpeechSurvivesQuietEndingWhilePreviewUsesRecentAudio() {
        var gate = AudioVolumeGate()
        gate.append([Float](repeating: -0.01, count: 8_000))
        gate.append([Float](repeating: 0, count: 24_000))
        XCTAssertTrue(gate.containsSignificantAudio)
        XCTAssertFalse(AudioVolumeGate.qualifies(gate.recentSamples[...]))
        XCTAssertEqual(gate.retainedSampleCount, 8_000)
    }
}

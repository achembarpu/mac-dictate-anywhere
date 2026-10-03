import XCTest
@testable import Dictate_Anywhere

final class AudioMonitorTests: XCTestCase {
    func testLevelBufferRetainsTheLatestWindowAcrossSmallCallbacks() {
        var buffer = AudioLevelSampleBuffer()
        let input = (0..<1_200).map(Float.init)
        for start in stride(from: 0, to: input.count, by: 100) {
            buffer.append(Array(input[start..<start + 100]))
        }
        XCTAssertEqual(buffer.samples, Array(input.suffix(AudioMonitor.windowSampleCount)))
        XCTAssertEqual(buffer.latest(count: 3), [1_197, 1_198, 1_199])
    }

    func testOversizedCallbackKeepsOnlyItsLatestWindow() {
        var buffer = AudioLevelSampleBuffer()
        buffer.append([99])
        let input = (0..<4_096).map(Float.init)
        buffer.append(input)
        buffer.append([])
        XCTAssertEqual(buffer.samples, Array(input.suffix(AudioMonitor.windowSampleCount)))
        XCTAssertEqual(buffer.latest(count: 10_000), buffer.samples)
    }

    func testLevelBufferHandlesEmptyNegativeAndResetRequests() {
        var buffer = AudioLevelSampleBuffer()
        XCTAssertTrue(buffer.latest(count: 100).isEmpty)
        buffer.append([1, 2, 3])
        XCTAssertTrue(buffer.latest(count: -1).isEmpty)
        XCTAssertTrue(buffer.latest(count: 0).isEmpty)
        buffer.reset(keepingCapacity: true)
        XCTAssertTrue(buffer.samples.isEmpty)
        buffer.append([4])
        XCTAssertEqual(buffer.samples, [4])
        buffer.reset(keepingCapacity: false)
        XCTAssertTrue(buffer.samples.isEmpty)
    }

    func testRMSIgnoresSamplesBeforeTheLatestWindow() {
        let monitor = AudioMonitor()
        let quietWindow = [Float](repeating: 0.1, count: AudioMonitor.windowSampleCount)
        let samples = [Float](repeating: 1, count: 100) + quietWindow
        monitor.update(samples: samples[...])
        let reference = AudioMonitor()
        reference.update(samples: quietWindow[...])
        XCTAssertEqual(monitor.smoothedLevel, reference.smoothedLevel, accuracy: 0.0001,
            "Earlier loud audio must not affect the current meter window")
    }

    func testEmptyWindowDoesNotChangeTheDisplayedLevel() {
        let monitor = AudioMonitor()
        monitor.update(samples: ArraySlice(repeating: Float(0.1), count: 800))
        let levelAfterAudio = monitor.smoothedLevel

        monitor.update(samples: ArraySlice<Float>())

        XCTAssertEqual(monitor.smoothedLevel, levelAfterAudio, accuracy: 0.0001)
    }
}

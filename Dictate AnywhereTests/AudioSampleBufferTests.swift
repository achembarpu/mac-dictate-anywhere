import XCTest
@testable import Dictate_Anywhere

final class AudioSampleBufferTests: XCTestCase {
    func testFrameConsumptionAndCompactionKeepEverySampleInOrder() {
        var buffer = AudioSampleBuffer()
        var consumed: [Float] = []
        for block in 0..<100 {
            buffer.append((0..<1_601).map { Float(block * 1_601 + $0) })
            while buffer.count >= 512 {
                consumed.append(contentsOf: buffer.samples.prefix(512))
                buffer.discardFirst(512)
            }
        }
        consumed.append(contentsOf: buffer.samples)
        XCTAssertEqual(consumed, (0..<160_100).map(Float.init))
        buffer.discardFirst(buffer.count)
        XCTAssertTrue(buffer.isEmpty)
        buffer.append([42, 43])
        XCTAssertEqual(Array(buffer.samples), [42, 43])
    }
}

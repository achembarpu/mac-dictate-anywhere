import AVFoundation
import XCTest
@testable import Dictate_Anywhere

final class PCMStreamConverterTests: XCTestCase {
    func testChunkedConversionMatchesWholeStreamAndPreservesDuration() throws {
        for (sourceRate, targetRate) in [(44_100.0, 16_000.0), (48_000.0, 16_000.0), (16_000.0, 48_000.0)] {
            let samples = (0..<Int(sourceRate)).map { Float(0.25 * sin(2 * .pi * 997 * Double($0) / sourceRate)) }
            let reference = try convert(samples, sourceRate: sourceRate, targetRate: targetRate, chunkSize: samples.count)
            XCTAssertEqual(reference.count, Int(targetRate))
            for chunkSize in [4_096, 1_379, 1_000] {
                let actual = try convert(samples, sourceRate: sourceRate, targetRate: targetRate, chunkSize: chunkSize)
                XCTAssertEqual(actual.count, reference.count, "\(sourceRate) → \(targetRate), block \(chunkSize)")
                let difference = zip(actual, reference).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(difference, 0.00001, "Conversion cannot re-prime or skip samples at a block boundary")
            }
        }
    }

    func testTinyInputsAndFinalTailRemainInOrder() throws {
        let samples = (0..<137).map { Float($0) / 137 }
        let reference = try convert(samples, sourceRate: 48_000, targetRate: 16_000, chunkSize: samples.count)
        let actual = try convert(samples, sourceRate: 48_000, targetRate: 16_000, chunkSize: 1)
        XCTAssertEqual(actual, reference)
        XCTAssertEqual(actual.count, 46)
    }

    func testFinishedStreamCannotAcceptMoreInputAndHasNoSecondTail() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try PCMStreamConverter(from: format, to: format)
        let buffer = try makePCMBuffer(from: [0.25, -0.5])
        XCTAssertTrue(try converter.convert(buffer).first === buffer)
        XCTAssertTrue(try converter.finish().isEmpty)
        XCTAssertTrue(try converter.finish().isEmpty)
        XCTAssertThrowsError(try converter.convert(buffer))
    }

    func testUnusedConversionEmitsNoSyntheticAudio() throws {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try PCMStreamConverter(from: source, to: output)
        XCTAssertTrue(try converter.finish().isEmpty)
    }

    func testNewStreamsCannotInheritFilterHistory() throws {
        let input = (0..<4_096).map { Float($0.isMultiple(of: 2) ? 0.25 : -0.25) }
        _ = try convert(input, sourceRate: 48_000, targetRate: 16_000, chunkSize: 1_379)
        let silence = try convert([Float](repeating: 0, count: 4_096), sourceRate: 48_000, targetRate: 16_000, chunkSize: 1_379)
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }

    func testFilePullsPreserveSamplesAndRetainedBuffersThroughFinalTail() throws {
        let samples: [Float] = (0..<160_137).map { index in
            let phase = 2.0 * Double.pi * 997.0 * Double(index) / 16_000.0
            return Float(0.25 * sin(phase))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try makePCMBuffer(from: samples)
        do {
            let file = try AVAudioFile(forWriting: url, settings: source.format.settings)
            try file.write(from: source)
        }
        for rate in [16_000.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let reader = try ConvertedRecoveryAudioReader(url: url, outputFormat: format)
            var retained: [AVAudioPCMBuffer] = []
            while let buffer = try reader.nextBuffer() { retained.append(buffer) }
            XCTAssertNil(try reader.nextBuffer(), "The filter tail is delivered once")
            // Async analyzer queues retain PCM buffers. Later pulls must never
            // overwrite samples already handed to those queues.
            let actual = retained.flatMap {
                Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)))
            }
            let reference = try convert(samples, sourceRate: 16_000, targetRate: rate, chunkSize: samples.count)
            XCTAssertEqual(actual, reference)
        }
    }

    func testFormatOnlyConversionFinishesAcrossRepeatedStreams() throws {
        let source = try makePCMBuffer(from: [Float](repeating: 0.25, count: 137))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: false))
        for _ in 0..<100 {
            let converter = try PCMStreamConverter(from: source.format, to: target)
            var output = try converter.convert(source)
            output.append(contentsOf: try converter.convert(source))
            output.append(contentsOf: try converter.finish())
            let values = output.flatMap {
                Array(UnsafeBufferPointer(start: $0.int16ChannelData![0], count: Int($0.frameLength)))
            }
            XCTAssertEqual(values.count, 274, "Format-only conversion has no missing or synthetic tail")
            XCTAssertTrue(values.allSatisfy { abs(Int($0) - 8_192) <= 1 })
        }
    }

    private func convert(_ samples: [Float], sourceRate: Double, targetRate: Double, chunkSize: Int) throws -> [Float] {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1))
        let converter = try PCMStreamConverter(from: source, to: target)
        var result: [Float] = []
        func collect(_ buffers: [AVAudioPCMBuffer]) {
            for buffer in buffers {
                result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
        }
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            let buffer = try makePCMBuffer(from: Array(samples[offset..<min(offset + chunkSize, samples.count)]), sampleRate: sourceRate)
            collect(try converter.convert(buffer))
        }
        collect(try converter.finish())
        return result
    }
}

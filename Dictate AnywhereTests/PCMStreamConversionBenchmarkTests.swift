#if PIPELINE_BENCHMARK
import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class PCMStreamConversionBenchmarkTests: XCTestCase {
    func testRecoveryPCMFilePullWork() throws {
        let samples = [Float](repeating: 0.125, count: 60 * 16_000)
        let source = try makePCMBuffer(from: samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: source.format.settings)
            try file.write(from: source)
        }
        let iterations = max(2, min(10, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        for type in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: type, sampleRate: 16_000, channels: 1, interleaved: false))
            for iteration in -1..<iterations {
                let order = iteration.isMultiple(of: 2) ? ["legacy-copy", "direct-pcm"] : ["direct-pcm", "legacy-copy"]
                for mode in order {
                    let before = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    var count = 0
                    if mode == "direct-pcm" {
                        let reader = try ConvertedRecoveryAudioReader(url: url, outputFormat: format)
                        while let buffer = try reader.nextBuffer() { count += Int(buffer.frameLength) }
                    } else {
                        let reader = try RecoveryAudioReader(url: url)
                        while let samples = try reader.nextSamples() {
                            let buffer = try makePCMBuffer(from: samples)
                            if buffer.format == format { count += Int(buffer.frameLength); continue }
                            let converter = try XCTUnwrap(AVAudioConverter(from: buffer.format, to: format))
                            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength + 8))
                            var supplied = false
                            var error: NSError?
                            let status = converter.convert(to: output, error: &error) { _, state in
                                if supplied { state.pointee = .noDataNow; return nil }
                                supplied = true; state.pointee = .haveData; return buffer
                            }
                            XCTAssertNotEqual(status, .error)
                            if let error { throw error }
                            count += Int(output.frameLength)
                        }
                    }
                    let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let after = try BenchmarkProcessResources.sample()
                    XCTAssertEqual(count, samples.count)
                    try printRow("PCM_FILE_PULL_RESULT", ["format": type == .pcmFormatFloat32 ? "float32" : "int16",
                        "mode": mode, "iteration": iteration, "latency_ms": elapsed,
                        "cpu_ms": after.cpuMilliseconds - before.cpuMilliseconds, "output_samples": count])
                }
            }
        }
    }

    func testCaptureConversionWorkAndSampleContinuity() throws {
        let iterations = max(1, min(10, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let samples = (0..<Int(rate * 10)).map { Float(0.25 * sin(2 * .pi * 997 * Double($0) / rate)) }
            let blocks = try blocks(samples, rate: rate)
            let reference = try resample(samples, from: rate, to: 16_000)
            for iteration in -1..<iterations {
                let order = iteration.isMultiple(of: 2) ? ["legacy-reset", "continuous"] : ["continuous", "legacy-reset"]
                for mode in order {
                    let resources = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    let output = try conversion(blocks, continuous: mode == "continuous")
                    let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let after = try BenchmarkProcessResources.sample()
                    if mode == "continuous" { XCTAssertEqual(output, reference) }
                    try printRow("PCM_CONVERSION_RESULT", ["rate": rate, "mode": mode, "iteration": iteration,
                        "latency_ms": elapsed, "cpu_ms": after.cpuMilliseconds - resources.cpuMilliseconds,
                        "process_peak_rss_bytes": after.peakResidentBytes, "input_samples": samples.count,
                        "output_samples": output.count, "reference_samples": reference.count])
                }
            }
        }
    }

    func testCaptureConversionOnGoldenSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = try XCTUnwrap(ParakeetModelChoice(rawValue: environment["PIPELINE_BENCHMARK_MODEL"] ?? "englishOnly"))
        let engine = ParakeetEngine()
        try XCTSkipUnless(model.isAvailableOnThisMac && engine.checkModelOnDisk(for: model), "Install selected speech model first")
        let inventory = try GoldenSpeechFixture.all()
        let ids = (environment["PIPELINE_BENCHMARK_FIXTURE"] ?? "golden-en-1,golden-en-ami-2,golden-en-ami-3,golden-en-boundaries").split(separator: ",").map(String.init)
        let fixtures = try ids.map { id in try XCTUnwrap(inventory.first { $0.id == id }) }
        let iterations = max(1, min(10, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "2") ?? 2))
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        defer { settings.parakeetModelChoice = oldModel; settings.selectedLanguage = oldLanguage }
        settings.parakeetModelChoice = model
        try await engine.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ran = 0
        for fixture in fixtures where fixture.supports(model) {
            settings.selectedLanguage = SupportedLanguage(rawValue: fixture.language) ?? .chinese
            let sourceURL = try fixture.audioURL
            XCTAssertEqual(hash(try Data(contentsOf: sourceURL)), fixture.audioSHA256)
            let reader = try RecoveryAudioReader(url: sourceURL)
            var samples: [Float] = []
            while let block = try reader.nextSamples() { samples.append(contentsOf: block) }
            XCTAssertEqual(samples.count, fixture.sampleCount)
            // Generate a representative microphone rate outside decode timers.
            let microphone = try resample(samples, from: 16_000, to: 48_000)
            let input = try blocks(microphone, rate: 48_000)
            let whole = try resample(microphone, from: 48_000, to: 16_000)
            let continuous = try conversion(input, continuous: true)
            XCTAssertEqual(continuous, whole, "Capture blocks must preserve the full stream")
            let variants = [("original", samples), ("whole-stream", whole),
                ("continuous", continuous), ("legacy-reset", try conversion(input, continuous: false))]
            for (variant, audio) in variants {
                let url = directory.appendingPathComponent(fixture.id + "-" + variant + ".wav")
                let buffer = try makePCMBuffer(from: audio)
                do {
                    let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
                    try file.write(from: buffer)
                }
                _ = try await engine.transcribeRecording(at: url)
                for iteration in 0..<iterations {
                    let start = ContinuousClock.now
                    let output = try await engine.transcribeRecording(at: url)
                    let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let inputHash = audio.withUnsafeBytes { hash(Data($0)) }
                    try printRow("PCM_ASR_RESULT", ["fixture": fixture.id, "model": model.rawValue,
                        "variant": variant, "iteration": iteration, "latency_ms": elapsed,
                        "input_samples": audio.count, "input_float32_sha256": inputHash,
                        "audio_sha256": fixture.audioSHA256, "error_rate": try fixture.errorRate(hypothesis: output),
                        "output": output, "path": "production_recording_file"])
                    ran += 1
                }
            }
        }
        try XCTSkipUnless(ran > 0, "No selected fixture is supported")
    }

    private func blocks(_ samples: [Float], rate: Double) throws -> [AVAudioPCMBuffer] {
        try stride(from: 0, to: samples.count, by: 4_096).map { offset in
            try makePCMBuffer(from: Array(samples[offset..<min(offset + 4_096, samples.count)]), sampleRate: rate)
        }
    }

    private func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        let source = try makePCMBuffer(from: samples, sampleRate: inputRate)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1))
        let converter = try PCMStreamConverter(from: source.format, to: format)
        return flatten(try converter.convert(source) + converter.finish())
    }

    private func conversion(_ blocks: [AVAudioPCMBuffer], continuous: Bool) throws -> [Float] {
        let source = try XCTUnwrap(blocks.first)
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var output: [Float] = []
        if continuous {
            let converter = try PCMStreamConverter(from: source.format, to: target)
            for block in blocks { output.append(contentsOf: flatten(try converter.convert(block))) }
            output.append(contentsOf: flatten(try converter.finish()))
        } else {
            // Frozen pre-fix capture conversion, including reset/floor/no tail.
            let converter = try XCTUnwrap(AVAudioConverter(from: source.format, to: target))
            for block in blocks {
                let capacity = AVAudioFrameCount(Double(block.frameLength) * 16_000 / block.format.sampleRate)
                guard capacity > 0 else { continue }
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
                converter.reset()
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true
                    state.pointee = .haveData
                    return block
                }
                XCTAssertNotEqual(status, .error)
                if let error { throw error }
                output.append(contentsOf: flatten([buffer]))
            }
        }
        return output
    }

    private func flatten(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        buffers.flatMap { Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func printRow(_ prefix: String, _ row: [String: Any]) throws {
        print(prefix + " " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
}
#endif

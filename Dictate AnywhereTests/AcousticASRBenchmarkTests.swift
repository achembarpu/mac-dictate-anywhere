import CryptoKit
import FluidAudio
import Foundation
import XCTest
@testable import Dictate_Anywhere

/// Separates model amplitude sensitivity from PCM16 quantization. Research
/// only: samples and references stay local, and product audio is not changed.
@MainActor
final class AcousticASRBenchmarkTests: XCTestCase {
    func testQuietFloatAudioAndPCM16GainScreen() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use the opt-in asr-acoustics benchmark group")
        #else
        let env = ProcessInfo.processInfo.environment
        let choice = try XCTUnwrap(ParakeetModelChoice(rawValue: env["PIPELINE_BENCHMARK_MODEL"] ?? "multilingual"))
        let version: AsrModelVersion
        switch choice {
        case .multilingual: version = .v3
        case .multilingualUltra: version = .ultra
        case .englishOnly: version = .v2
        case .compactEnglish: version = .tdtCtc110m
        default: throw XCTSkip("Select one TDT model")
        }
        try XCTSkipUnless(choice.isAvailableOnThisMac && ParakeetEngine().checkModelOnDisk(for: choice), "Selected model is not installed/available")
        let fixtures = try GoldenSpeechFixture.all()
        let fixture = try XCTUnwrap(fixtures.first { $0.id == (env["PIPELINE_BENCHMARK_FIXTURE"] ?? "golden-en-fleurs-1") })
        try XCTSkipUnless(fixture.supports(choice), "Model does not support fixture language")
        let audio = try read(fixture)
        let quietFloat = audio.map { $0 * 0.1 }
        var variants: [(name: String, samples: [Float], reference: String)] = [
            ("reference-pcm16", audio, try fixture.referenceText),
            ("reference-gain4", amplify(audio, gain: 4), try fixture.referenceText),
            ("reference-gain64", amplify(audio, gain: 64), try fixture.referenceText)
        ]
        for gain: Float in [1, 4, 16, 64] {
            variants.append(("float32-quiet-gain\(Int(gain))", amplify(quietFloat, gain: gain), try fixture.referenceText))
        }
        if let quiet = fixtures.first(where: { $0.id == fixture.id + "-quiet" }) {
            XCTAssertEqual(try quiet.referenceText, try fixture.referenceText)
            let pcmQuiet = try read(quiet)
            for gain: Float in [1, 4, 16, 64] {
                variants.append(("pcm16-quiet-gain\(Int(gain))", amplify(pcmQuiet, gain: gain), try fixture.referenceText))
            }
        }
        variants.append(("silence", [Float](repeating: 0, count: 16_000), ""))
        // Deterministic zero-mean broadband control, not an environmental
        // noise dataset. The amplified copy checks a gain-induced false positive.
        var seed: UInt64 = 2468
        let noise: [Float] = (0..<16_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 0.01
        }
        variants.append(("uniform-noise", noise, ""))
        variants.append(("uniform-noise-gain16", amplify(noise, gain: 16), ""))
        if let selection = env["PIPELINE_BENCHMARK_ACOUSTIC_VARIANTS"] {
            let names = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard Set(names).count == names.count else {
                XCTFail("Select each acoustic variant once")
                return
            }
            variants = try names.map { name in
                try XCTUnwrap(variants.first { $0.name == name }, "Unknown acoustic variant: \(name)")
            }
        }
        let iterations = max(1, min(10, Int(env["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
        do {
            try await manager.loadModels(AsrModels.loadFromCache(version: version))
            let layers = await manager.decoderLayerCount
            for variant in variants {
                let inputHash = variant.samples.withUnsafeBytes { SHA256.hash(data: Data($0)) }
                    .map { String(format: "%02x", $0) }.joined()
                let peak = variant.samples.reduce(Float(0)) { max($0, abs($1)) }
                let rms = sqrt(variant.samples.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(variant.samples.count))
                var warmState = TdtDecoderState.make(decoderLayers: layers)
                _ = try await manager.transcribe(variant.samples, decoderState: &warmState)
                for iteration in 0..<iterations {
                    try Task.checkCancellation()
                    var state = TdtDecoderState.make(decoderLayers: layers)
                    let resourcesBefore = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    let result = try await manager.transcribe(variant.samples, decoderState: &state)
                    let latency = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let resourcesAfter = try BenchmarkProcessResources.sample()
                    let row: [String: Any] = ["model": choice.rawValue, "fixture": fixture.id, "variant": variant.name,
                        "iteration": iteration, "latency_ms": latency,
                        "cpu_ms": resourcesAfter.cpuMilliseconds - resourcesBefore.cpuMilliseconds,
                        "process_peak_rss_bytes": resourcesAfter.peakResidentBytes,
                        "input_float32_sha256": inputHash, "input_peak": peak, "input_rms": rms,
                        "input_samples": variant.samples.count, "output": result.text,
                        "error_rate": GoldenSpeechFixture.errorRate(reference: variant.reference, hypothesis: result.text, metric: fixture.metric),
                        "nonspeech_control": variant.reference.isEmpty, "path": "sdk_raw_samples"]
                    print("ASR_ACOUSTIC_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                }
            }
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }
        #endif
    }

    private func read(_ fixture: GoldenSpeechFixture) throws -> [Float] {
        let url = try fixture.audioURL
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, fixture.audioSHA256)
        let reader = try RecoveryAudioReader(url: url)
        var samples: [Float] = []
        while let chunk = try reader.nextSamples() { samples.append(contentsOf: chunk) }
        XCTAssertEqual(samples.count, fixture.sampleCount)
        return samples
    }

    private func amplify(_ samples: [Float], gain: Float) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        // Gain labels are ceilings. Keep arbitrary selected fixtures within
        // normalized Float32 range rather than silently clipping their peaks.
        let applied = peak > 0 ? min(gain, 0.99 / peak) : gain
        return samples.map { $0 * applied }
    }
}

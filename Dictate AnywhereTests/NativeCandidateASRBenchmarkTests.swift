import CryptoKit
import FluidAudio
import Foundation
import XCTest
@testable import Dictate_Anywhere

/// Screens SDK candidates without adding them to the product model picker.
/// Uses the same golden files, scorer and configuration as native app checks.
@MainActor
final class NativeCandidateASRBenchmarkTests: XCTestCase {
    func testNativeCoreMLCandidateOnGoldenFiles() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use the opt-in asr-candidates benchmark group")
        #else
        let environment = ProcessInfo.processInfo.environment
        let name = environment["PIPELINE_BENCHMARK_MODEL"] ?? "phonon2"
        let version: AsrModelVersion
        switch name {
        case "phonon2":
            #if arch(arm64)
            guard #available(macOS 15, *) else { throw XCTSkip("Phonon-2 requires macOS 15") }
            version = .phonon2
            #else
            throw XCTSkip("This Phonon-2 screen targets the Apple Silicon Neural Engine")
            #endif
        case "multilingual": version = .v3
        case "multilingualUltra": version = .ultra
        default: throw XCTSkip("Select phonon2, multilingual or multilingualUltra")
        }
        var fixtures = try GoldenSpeechFixture.all().filter { $0.language == "en" }
        if let selection = environment["PIPELINE_BENCHMARK_FIXTURE"] {
            let ids = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard Set(ids).count == ids.count else {
                XCTFail("Select each golden fixture once")
                return
            }
            fixtures = try ids.map { id in
                try XCTUnwrap(fixtures.first { $0.id == id }, "Select exact English golden IDs")
            }
        }
        let iterations = max(1, min(10, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
        let manifestHash = SHA256.hash(data: try Data(contentsOf: GoldenSpeechFixture.resource("golden-speech-manifest.json")))
            .map { String(format: "%02x", $0) }.joined()
        let cache = AsrModels.defaultCacheDirectory(for: version)
        let downloadsAllowed = environment["PIPELINE_BENCHMARK_DOWNLOAD_MODELS"] == "1"
        try XCTSkipUnless(downloadsAllowed || AsrModels.modelsExist(at: cache, version: version), "Selected candidate is not installed; explicitly opt in to its download")
        let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig)
        do {
            let preparationStart = ContinuousClock.now
            let models: AsrModels
            if downloadsAllowed {
                // The SDK's normal persistent app cache; no benchmark-only copy.
                models = try await AsrModels.downloadAndLoad(version: version)
            } else {
                models = try AsrModels.loadLocal(from: cache, version: version)
            }
            try await manager.loadModels(models)
            let preparationMs = BenchmarkStatistics.elapsedMilliseconds(from: preparationStart)
            let layers = await manager.decoderLayerCount
            for fixture in fixtures {
                try Task.checkCancellation()
                let url = try fixture.audioURL
                let audioHash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(audioHash, fixture.audioSHA256)
                let referenceHash = SHA256.hash(data: try Data(contentsOf: GoldenSpeechFixture.resource(fixture.reference)))
                    .map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(referenceHash, fixture.referenceSHA256)
                var warmState = TdtDecoderState.make(decoderLayers: layers)
                let firstStart = ContinuousClock.now
                _ = try await manager.transcribe(url, decoderState: &warmState)
                let firstMs = BenchmarkStatistics.elapsedMilliseconds(from: firstStart)
                for iteration in 0..<iterations {
                    try Task.checkCancellation()
                    var state = TdtDecoderState.make(decoderLayers: layers)
                    let before = try BenchmarkProcessResources.sample()
                    let start = ContinuousClock.now
                    let result = try await manager.transcribe(url, decoderState: &state)
                    let latencyMs = BenchmarkStatistics.elapsedMilliseconds(from: start)
                    let after = try BenchmarkProcessResources.sample()
                    let row: [String: Any] = [
                        "model": name, "fixture": fixture.id, "iteration": iteration,
                        "latency_ms": latencyMs, "first_file_ms": firstMs,
                        "preparation_ms": preparationMs, "audio_sha256": audioHash,
                        "reference_sha256": referenceHash, "manifest_sha256": manifestHash,
                        "audio_seconds": Double(fixture.sampleCount) / 16_000,
                        "cpu_ms": after.cpuMilliseconds - before.cpuMilliseconds,
                        "process_peak_rss_bytes": after.peakResidentBytes,
                        "output": result.text, "error_rate": try fixture.errorRate(hypothesis: result.text),
                        "path": "sdk_recording_file", "encoder_compute_units": "cpuAndNeuralEngine"
                    ]
                    print("ASR_CANDIDATE_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                }
            }
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }
        #endif
    }
}

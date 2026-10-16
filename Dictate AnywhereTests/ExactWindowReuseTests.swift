import XCTest
import FluidAudio
@testable import Dictate_Anywhere

/// Protect recording isolation and full final authority, including the production
/// vocabulary path that used to cancel its preview session before final decoding.
@MainActor
final class ExactWindowReuseTests: XCTestCase {
    private func speechSamples() throws -> [Float] {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_RECOVERY_ASR_TESTS"] == "1",
                          "Set RUN_RECOVERY_ASR_TESTS=1 with installed v2 and 110M models")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "en-recovery", withExtension: "wav"))
        let reader = try RecoveryAudioReader(url: url)
        var samples: [Float] = []
        while let block = try reader.nextSamples(maxSamples: 16_000) { samples.append(contentsOf: block) }
        return samples + samples + samples
    }

    func testCompleteBatchAndFreshVocabularyFinalMatchWithoutReuse() async throws {
        let samples = try speechSamples()
        let wasOffline = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = wasOffline }
        for (model, version): (ParakeetModelChoice, AsrModelVersion) in [(.englishOnly, .v2), (.compactEnglish, .tdtCtc110m)] {
            let models = try AsrModels.loadLocal(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let coordinator = AsrManagerCoordinator(vadModelURL: URL(fileURLWithPath: "/missing/optional-vad"))
            try await coordinator.initialize(models: models, config: BatchTranscriptionPolicy.asrConfig)
            let terms = ["cancellation"]
            try await coordinator.prepareVocabulary(terms: terms)
            let baseline = try await coordinator.transcribeWithCustomVocabulary(samples, terms: terms, language: .english)
            try await coordinator.resetSession(for: model, language: .english, requiresWholeRecordingFinal: true,
                                               previewsEnabled: true, exactWindowReuseEnabled: true)
            for offset in stride(from: 0, to: samples.count, by: 2 * 16_000) {
                try await coordinator.appendBatchAudio(Array(samples[offset..<min(offset + 2 * 16_000, samples.count)]))
                _ = try await coordinator.batchPreview()
            }
            let warm = await coordinator.exactWindowReuseStatisticsForTesting()
            XCTAssertGreaterThan(warm.hits, 0, "Previews must warm identical completed windows")
            let cached = try await coordinator.finishBatchWithCustomVocabulary(samples, terms: terms, language: .english)
            let completed = await coordinator.completedWindowReuseStatisticsForTesting
            XCTAssertGreaterThan(try XCTUnwrap(completed).hits, warm.hits,
                                 "Vocabulary finalization must reuse previews before retiring the cache")
            XCTAssertEqual(cached.text, baseline.text, model.rawValue)
            XCTAssertEqual(cached.confidence, baseline.confidence)
            XCTAssertEqual(cached.duration, baseline.duration)
            let retired = await coordinator.exactWindowReuseStatisticsForTesting()
            XCTAssertEqual(retired.entries, 0, "Final vocabulary work must release the recording cache")
            let words = cached.text.lowercased().split { !$0.isLetter }
            XCTAssertEqual(words.filter { $0 == "weather" }.count, 3, cached.text)
            XCTAssertEqual(words.filter { $0 == "cancellation" }.count, 3, cached.text)
            await coordinator.cleanup()
        }
    }

    // Prevent unbounded prefix work and ensure disabling/cancelling cannot leave
    // reusable requests resident for the next recording, even with hidden previews.
    func testLongRecordingDisableAndCancellationRetireReuse() async throws {
        let samples = try speechSamples()
        let models = try AsrModels.loadLocal(from: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig, models: models)
        func session(previews: Bool = true) async throws -> BatchTranscriptionSession {
            try await BatchTranscriptionSession.parakeet(models: models, previewManager: manager, vad: nil,
                language: .english, requiresWholeRecordingFinal: true, previewsEnabled: previews,
                exactWindowReuseEnabled: true)
        }
        for reason in ["duration", "disabled", "cancelled", "hidden"] {
            let recording = try await session(previews: reason != "hidden")
            try await recording.append(samples)
            _ = try await recording.preview()
            let warm = await manager.batchWindowReuseExperimentStatistics()
            if reason == "hidden" {
                XCTAssertEqual(warm.entries, 0)
            } else {
                XCTAssertGreaterThan(warm.entries, 0)
                switch reason {
                case "duration":
                    for _ in 0..<4 { try await recording.append(samples) }
                case "disabled":
                    try await recording.append([], allowExactWindowReuse: false)
                default: await recording.cancel()
                }
                let retired = await manager.batchWindowReuseExperimentStatistics()
                XCTAssertEqual(retired.entries, 0, reason)
                try await recording.append(Array(samples.prefix(16_000)))
                _ = try await recording.preview()
                let resumed = await manager.batchWindowReuseExperimentStatistics()
                XCTAssertEqual(resumed.entries, 0, "Must not reactivate reuse in the same recording")
            }
            await recording.cancel()
        }
        await manager.cleanup()
    }
}

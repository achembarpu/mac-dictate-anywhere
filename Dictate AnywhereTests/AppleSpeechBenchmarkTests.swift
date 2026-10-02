import Speech
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class AppleSpeechBenchmarkTests: XCTestCase {
    func testInstalledLocalesGoldenSpeechAndFreshSessionPreparation() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Use scripts/dev.sh benchmark --only apple-speech-quality")
        #else
        guard #available(macOS 26, *), AppleSpeechEngine.isSupported else { throw XCTSkip("Apple Speech unavailable") }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let filter = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_FIXTURE"]
        let allowsInstallation = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_DOWNLOAD_MODELS"] == "1"
        var ran = 0
        for fixture in try GoldenSpeechFixture.all() {
            guard fixture.language != "zh-en", filter == nil || filter == fixture.id else { continue }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: AppleSpeechEngine.locale(forLanguageCode: fixture.language)),
                  allowsInstallation || installed.contains(locale.identifier(.bcp47)) else { continue }
            var rates: [Double] = []
            for iteration in 0..<2 {
                let prepStart = ContinuousClock.now
                // Never download assets silently. Test the same fresh-session
                // and bounded file-reader path used by recording recovery.
                let session: AppleSpeechSession
                do {
                    session = try await AppleSpeechSession(requestedLocale: locale, contextualVocabulary: [],
                        allowsAssetInstallation: allowsInstallation, onTranscript: { _, _ in })
                } catch TranscriptionError.appleSpeechLanguageUnsupported where !allowsInstallation {
                    // installedLocales can list a locale whose requested
                    // transcriber still reports an asset installation request.
                    print("APPLE_SPEECH_SKIP fixture=\(fixture.id) reason=assets-not-ready")
                    break
                } catch where (error as NSError).domain == "SFSpeechErrorDomain"
                    && (error as NSError).code == 1
                    && error.localizedDescription.contains("asset unavailable") {
                    print("APPLE_SPEECH_SKIP fixture=\(fixture.id) reason=system-asset-unavailable-after-download")
                    break
                }
                let preparation = BenchmarkStatistics.elapsedMilliseconds(from: prepStart)
                let start = ContinuousClock.now
                let text = try await session.transcribeFile(at: fixture.audioURL)
                let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: start)
                let rate = try fixture.errorRate(hypothesis: text)
                rates.append(rate)
                print("APPLE_SPEECH_GOLDEN fixture=\(fixture.id) locale=\(locale.identifier(.bcp47)) iteration=\(iteration) prepare_ms=\(preparation) latency_ms=\(elapsed) error_rate=\(rate) output_chars=\(text.count)")
                XCTAssertFalse(text.isEmpty, fixture.id)
                await session.cancel()
            }
            // Same preset/audio must retain final quality when a new prepared
            // session follows an earlier finalized session.
            if rates.count == 2 {
                XCTAssertEqual(rates[0], rates[1], accuracy: 0.000_001, fixture.id)
                ran += 1
            }
        }
        try XCTSkipIf(ran == 0, "No installed locale matches the selected golden fixture")
        #endif
    }
}

#if PIPELINE_BENCHMARK
import XCTest
import os
@testable import Dictate_Anywhere

/// Installed-model lifecycle regressions. Select --only s1-regressions and an explicit model path.
final class S1MiniModelTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(realModelPath() != nil, "Set S1_MINI_MODEL_PATH to run installed-model regressions")
    }

    override func tearDown() async throws {
        #if DEBUG
        PerfTrace.onIntervalCompleted = nil
        #endif
        await S1MiniInferenceEngine.shared.configureCacheForTesting(f16: nil)
        await S1MiniPostProcessingService.unload()
        try await super.tearDown()
    }

    func testRealContextReuseMatchesFreshRequestsAndClearsHistory() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check context reuse") }
        let url = URL(fileURLWithPath: path)
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        let fixtures = try GoldenCleanupFixture.all().filter {
            $0.language == "en" && $0.vocabulary == nil && $0.id != "long-complete-ending"
        }
        var baseline: [String: String] = [:]
        for fixture in fixtures {
            await engine.discardInferenceContextForTesting()
            baseline[fixture.id] = try await process(fixture.input, modelURL: url)
        }
        // Reverse order so previous requests have different names, numbers,
        // intent and prompt lengths than the fresh-context baseline.
        for fixture in fixtures.reversed() {
            let output = try await process(fixture.input, modelURL: url)
            XCTAssertEqual(output, baseline[fixture.id], fixture.id)
            XCTAssertTrue(fixture.violations(in: output).isEmpty, fixture.id)
            let state = await engine.inferenceContextStateForTesting()
            XCTAssertTrue(state.allocated)
            XCTAssertEqual(state.maximumPosition, -1, "A completed request retained KV token positions")
            let ready = await S1MiniPostProcessingService.isPrepared(modelURL: url)
            XCTAssertTrue(ready, "Successful first use prepares the retained runtime")
        }
        await engine.unload()
        let state = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(state.allocated)
    }

    func testRealModelPathChangeReleasesContextBeforeReplacingWeights() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check context ownership") }
        let url = URL(fileURLWithPath: path)
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("s1-context-model-\(UUID()).gguf")
        try FileManager.default.linkItem(at: url, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        _ = try await engine.transcriptChunks("Hello.", modelURL: alias)
        let state = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(state.allocated, "A context must not outlive the model it references")
        let output = try await process("Send invoice 43 on Thursday.", modelURL: alias)
        XCTAssertTrue(output.contains("43"))
        XCTAssertTrue(output.lowercased().contains("thursday"))
    }

    #if DEBUG
    func testRealCancellationAfterPromptDiscardsContextAndNextRequestRecovers() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check cancelled context") }
        let url = URL(fileURLWithPath: path)
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "cleanup.prefillSchedule" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        defer { PerfTrace.onIntervalCompleted = nil }
        let cancelled = Task {
            try await self.process("Please send invoice 812 to Mara.", modelURL: url)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation after prompt evaluation")
        } catch is CancellationError {
            // The context contained a real prompt before cancellation.
        }
        PerfTrace.onIntervalCompleted = nil
        let discarded = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(discarded.allocated)
        let readyAfterCancellation = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertFalse(readyAfterCancellation)
        let recovered = try await process("Keep invoice 43 for Nadia.", modelURL: url)
        XCTAssertTrue(recovered.contains("43"))
        XCTAssertTrue(recovered.lowercased().contains("nadia"))
        XCTAssertFalse(recovered.contains("812"))
        XCTAssertFalse(recovered.lowercased().contains("mara"))
    }
    #endif

    func testRealPrewarmRunsInferenceOnceAndKeepsTheNextRequestIndependent() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check inference prewarm") }
        let url = URL(fileURLWithPath: path)
        await S1MiniPostProcessingService.unload()
        let firstReady = await S1MiniPostProcessingService.prewarm(modelURL: url)
        let runtimeReady = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertEqual(runtimeReady, firstReady)
        XCTAssertTrue(firstReady)
        #if DEBUG || PIPELINE_BENCHMARK
        let prepared = await S1MiniInferenceEngine.shared.inferenceContextStateForTesting()
        XCTAssertTrue(prepared.allocated, "Prewarm must retain the inference allocations")
        XCTAssertEqual(prepared.maximumPosition, -1, "Synthetic warmup must clear its KV cache")
        #endif
        #if DEBUG
        let events = OSAllocatedUnfairLock(initialState: [String]())
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "cleanup.generate" { events.withLock { $0.append(name) } }
        }
        #endif
        let secondReady = await S1MiniPostProcessingService.prewarm(modelURL: url)
        XCTAssertTrue(secondReady)
        #if DEBUG
        PerfTrace.onIntervalCompleted = nil
        XCTAssertTrue(events.withLock { $0.isEmpty }, "An already-warm model must not repeat synthetic inference")
        #endif
        let output = try await process("Send invoice 43 on Friday no sorry Thursday.", modelURL: url)
        XCTAssertTrue(output.contains("43"))
        XCTAssertTrue(output.lowercased().contains("thursday"))
        XCTAssertFalse(output.lowercased().contains("hello"))
        XCTAssertFalse(output.lowercased().contains("friday"))
    }

    func testRealRepeatedLongTranscriptCannotLoseNumbersWhenModelIsAvailable() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check real long-input cleanup") }
        let text = (1...110).map { "Please keep invoice \($0) and send the report tomorrow." }.joined(separator: " ")
        let url = URL(fileURLWithPath: path)
        let chunks = try await S1MiniInferenceEngine.shared.transcriptChunks(text, modelURL: url)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        let output = try await process(text, modelURL: url)
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.lowercased().contains("invoice"))
        XCTAssertTrue(output.lowercased().contains("tomorrow"))
        let numbers = output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        XCTAssertEqual(Set(numbers), Set(1...110), "Cleanup lost an invoice number around a chunk boundary")
    }

    func testRealVariedLongTranscriptCleansFinalCorrectionWhenModelIsAvailable() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check real long-input cleanup") }
        let reference = try XCTUnwrap(GoldenSpeechFixture.all().first { $0.id == "golden-en-boundaries" }).referenceText
        let text = Array(repeating: reference, count: 5).joined(separator: "\n\n")
            + "\nUm please send the final report to Utrecht on Friday no sorry Thursday."
        let url = URL(fileURLWithPath: path)
        let chunks = try await S1MiniInferenceEngine.shared.transcriptChunks(text, modelURL: url)
        XCTAssertGreaterThan(chunks.count, 1)
        let output = try await process(text, modelURL: url)
        XCTAssertTrue(output.lowercased().contains("utrecht"))
        XCTAssertTrue(output.lowercased().contains("thursday"))
        XCTAssertFalse(output.lowercased().contains("friday"), "Long input fell back to uncorrected text")
    }

    func testModelManagerValidatesAndDeletesInstalledModelWhenRealModelExists() async throws {
        let sourcePath = realModelPath()
        guard let sourcePath else {
            throw XCTSkip("Set S1_MINI_MODEL_PATH to run the verified model lifecycle test.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let installedURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try FileManager.default.linkItem(
            at: URL(fileURLWithPath: sourcePath),
            to: installedURL
        )
        try Data("S1-mini license".utf8).write(
            to: directory.appendingPathComponent("LICENSE"),
            options: .atomic
        )

        let manager = S1MiniModelManager(modelDirectory: directory)
        let validatedURL = try await manager.validatedModelURL()
        XCTAssertEqual(validatedURL, installedURL)
        XCTAssertTrue(manager.isModelDownloaded)

        try await manager.deleteModel()
        XCTAssertFalse(manager.isModelDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath))
    }

    func testRealModelWhenPathIsProvided() async throws {
        let path = realModelPath()
        guard let path else {
            throw XCTSkip("Set S1_MINI_MODEL_PATH to run the local inference smoke test.")
        }

        let modelURL = URL(fileURLWithPath: path)
        let correction = try await process(
            "so um i need to like send the the report by uh friday no wait make that thursday",
            modelURL: modelURL
        )
        XCTAssertFalse(correction.lowercased().contains(" um "))
        XCTAssertFalse(correction.lowercased().contains(" uh "))
        XCTAssertFalse(correction.contains("Friday"))
        XCTAssertTrue(correction.contains("Thursday"))

        let numberCorrection = try await process(
            "i think the answer is forty two no sorry forty three",
            modelURL: modelURL
        )
        XCTAssertTrue(numberCorrection.contains("43"), numberCorrection)
        XCTAssertFalse(numberCorrection.contains("42"), numberCorrection)

        let timeCorrection = try await process(
            "let's meet at half past two tomorrow uh actually make it three fifteen p m",
            modelURL: modelURL
        )
        XCTAssertTrue(timeCorrection.contains("3:15"), timeCorrection)
        XCTAssertFalse(timeCorrection.contains("2:30"), timeCorrection)

        let invoice = try await process(
            "the invoice came to twenty three thousand four hundred and fifty dollars and it's due on march third twenty twenty six",
            modelURL: modelURL
        )
        XCTAssertTrue(invoice.contains("$23,450"), invoice)
        XCTAssertTrue(invoice.contains("March 3"), invoice)
        XCTAssertTrue(invoice.contains("2026"), invoice)

        let email = try await process(
            "send it to support at superwhisper dot com",
            modelURL: modelURL
        )
        XCTAssertFalse(email.isEmpty)
    }

    private func realModelPath() -> String? {
        ProcessInfo.processInfo.environment["S1_MINI_MODEL_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func process(_ text: String, modelURL: URL) async throws -> String {
        try await S1MiniPostProcessingService.process(
            text: text,
            modelURL: modelURL,
            styling: .semiFormal,
            structure: .prose,
            contextSetting: .general,
            context: nil
        )
    }
}
#endif

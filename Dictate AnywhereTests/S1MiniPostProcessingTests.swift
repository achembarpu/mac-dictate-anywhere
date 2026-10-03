import XCTest
@testable import Dictate_Anywhere

final class S1MiniPostProcessingTests: XCTestCase {
    func testModelRemovalInvalidatesThePreparedRuntimeRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-removal-\(UUID())")
        let manager = S1MiniModelManager(modelDirectory: directory)
        let previousRevision = manager.runtimeRevision
        try await manager.deleteModel()
        XCTAssertNotEqual(manager.runtimeRevision, previousRevision, "Reinstalling at the same path must not restore an old Ready status")
        XCTAssertFalse(manager.isModelDownloaded)
    }

    func testLiteralMarkerFallbackDoesNotClaimPreparedRuntime() async throws {
        await S1MiniPostProcessingService.unload()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-readiness-\(UUID()).gguf")
        let text = "Keep the literal <|im_start|> marker."
        let output = try await S1MiniPostProcessingService.process(text: text, modelURL: url,
            styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil)
        XCTAssertEqual(output, text)
        let ready = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertFalse(ready)
    }

    func testLongTranscriptChunksPreserveSentencesAndEveryCharacter() throws {
        let text = "Please send the report.\nWe need it tomorrow. Keep the invoice for 23 dollars."
        let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 7) {
            $0.split(whereSeparator: \.isWhitespace).count
        }
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasSuffix(".\n"))
        XCTAssertTrue(chunks.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 7 })
    }

    func testLongSentenceChunksAtWordBoundariesAndShortTextStaysWhole() throws {
        let text = "one two three four five six seven eight nine ten"
        let count: (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count }
        let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 4, tokenCount: count)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.last?.isWhitespace == true })
        XCTAssertTrue(chunks.allSatisfy { count($0) <= 4 })
        XCTAssertEqual(try S1MiniTranscriptChunker.chunks("Keep 43.", maximumTokens: 4, tokenCount: count), ["Keep 43."])
        XCTAssertThrowsError(try S1MiniTranscriptChunker.chunks("unbroken", maximumTokens: 3, tokenCount: { $0.count }))
    }

    func testPromptMatchesRequiredNonThinkingTrainingFormat() {
        let prompt = S1MiniPromptBuilder.prompt(
            transcript: "so um send it friday",
            styling: .semiFormal,
            structure: .prose,
            context: "general"
        )

        XCTAssertEqual(
            prompt,
            """
            <|im_start|>system
            You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.<|im_end|>
            <|im_start|>user
            [Styling: semi-formal] [Structure: prose] [Context: general]
            so um send it friday<|im_end|>
            <|im_start|>assistant
            <think>

            </think>

            """ + "\n"
        )
    }

    func testAutomaticContextUsesEmailOnlyForEmailDestinations() {
        XCTAssertEqual(S1MiniContextSetting.automatic.resolved(for: nil), "general")
        XCTAssertEqual(
            S1MiniContextSetting.automatic.resolved(for: context(category: .workMessaging)),
            "general"
        )
        XCTAssertEqual(
            S1MiniContextSetting.automatic.resolved(for: context(category: .email)),
            "email"
        )
    }

    func testAppStylingCanOverrideEachCategoryIndependently() {
        var styling = S1MiniAppStyling.uniform(.semiFormal)

        styling.set(.formal, for: .email)
        styling.set(.casual, for: .personalMessaging)

        XCTAssertEqual(styling.styling(for: .email), .formal)
        XCTAssertEqual(styling.styling(for: .workMessaging), .semiFormal)
        XCTAssertEqual(styling.styling(for: .personalMessaging), .casual)
        XCTAssertEqual(styling.styling(for: .other), .semiFormal)
    }

    func testDownloadProgressUsesPinnedSizeForUnknownOrMismatchedServerLength() {
        for serverLength in [NSURLSessionTransferSizeUnknown, 1_024] {
            let fraction = S1MiniDownloadProgress.transferFraction(
                totalBytesWritten: S1MiniModelSpec.byteCount / 4,
                serverExpectedByteCount: serverLength
            )

            XCTAssertEqual(fraction, 0.25, accuracy: 0.000_001)
        }
    }

    func testTransferProgressIsMonotonicAndReservesFinalInstallationWork() {
        var previous = 0.0
        for fraction in [0.1, 0.5, 0.25, 1.0] {
            let next = S1MiniDownloadProgress.installationProgress(current: previous, transferFraction: fraction)
            XCTAssertGreaterThanOrEqual(next, previous, "Server updates must not move progress backwards")
            XCTAssertLessThan(next, 1, "A finished transfer must still wait for installation and verification")
            previous = next
        }
        XCTAssertGreaterThan(previous, 0)
    }

    func testStreamingSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try S1MiniModelIntegrity.sha256(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testIntegrityRejectsWrongFileSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-invalid-\(UUID().uuidString).gguf")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try S1MiniModelIntegrity.validate(url)) { error in
            guard case S1MiniModelManagerError.unexpectedFileSize = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testInstallationRequiresDownloadedLicense() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-license-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let modelURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        XCTAssertTrue(FileManager.default.createFile(atPath: modelURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: modelURL)
        try handle.truncate(atOffset: UInt64(S1MiniModelSpec.byteCount))
        try handle.close()

        XCTAssertFalse(S1MiniModelManager(modelDirectory: directory).isModelDownloaded)

        try Data("S1-mini license".utf8).write(
            to: directory.appendingPathComponent("LICENSE"),
            options: .atomic
        )
        XCTAssertTrue(S1MiniModelManager(modelDirectory: directory).isModelDownloaded)
    }

    @MainActor
    func testStartupRefreshAndPrewarmShareOneIntegrityCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-concurrent-validation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try Data().write(to: modelURL)
        let modelFile = try FileHandle(forWritingTo: modelURL)
        try modelFile.truncate(atOffset: UInt64(S1MiniModelSpec.byteCount))
        try modelFile.close()
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))

        let started = expectation(description: "integrity check started")
        let gate = S1ValidationGate(started: started)
        let manager = S1MiniModelManager(modelDirectory: directory) { _ in
            try gate.validate()
        }
        let refresh = Task { await manager.refreshInstallationState() }
        await fulfillment(of: [started], timeout: 5)
        let prewarm = Task { try await manager.validatedModelURL() }
        try await Task.sleep(for: .milliseconds(30))

        gate.release()
        await refresh.value
        let validatedURL = try await prewarm.value
        XCTAssertEqual(validatedURL, manager.modelURL)
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertFalse(manager.isVerifying)
    }

    @MainActor
    func testRefreshWithoutInstalledModelDoesNotReportDownloadFailure() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-not-installed-\(UUID())", isDirectory: true)
        let manager = S1MiniModelManager(modelDirectory: directory)

        await manager.refreshInstallationState()

        XCTAssertFalse(manager.isModelDownloaded)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isVerifying)
    }

    private func context(category: DictationContextCategory) -> DictationPostProcessingContext {
        DictationPostProcessingContext(
            category: category,
            style: .neutral,
            cursorPlacement: .emptyField,
            continuesExistingSentence: false,
            appName: nil,
            documentURL: nil,
            documentTitle: nil,
            fieldRole: nil,
            fieldPurpose: .unknown,
            textBeforeCursor: nil,
            selectedText: nil,
            textAfterCursor: nil
        )
    }
}

private nonisolated final class S1ValidationGate: @unchecked Sendable {
    private let started: XCTestExpectation
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var count = 0

    init(started: XCTestExpectation) { self.started = started }

    var callCount: Int { lock.withLock { count } }

    func validate() throws {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        if first { started.fulfill() }
        guard releaseSemaphore.wait(timeout: .now() + 5) == .success else {
            throw S1MiniModelManagerError.checksumMismatch
        }
    }

    func release() {
        releaseSemaphore.signal()
        releaseSemaphore.signal()
    }
}

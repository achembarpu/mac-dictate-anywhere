import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniMLXTests: XCTestCase {
    #if arch(arm64)
    func testRealMLXPrewarmIndependentRequestsAndUnload() async throws {
        let url = try realMLXModel()
        let engine = S1MiniMLXInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        let prefixDigest = await engine.publicPrefixDigestForTesting()
        let prepared = await engine.stateForTesting()
        XCTAssertTrue(prepared.loaded && prepared.warmed)
        XCTAssertEqual(Set(prepared.prefixPositions).count, 1)
        XCTAssertGreaterThan(prepared.prefixPositions.first ?? 0, 0)
        let first = try await cleanup("please send invoice 4182 to Mara and do not include the draft", url: url)
        _ = try await cleanup("book it on Monday no sorry Tuesday at 4 PM", url: url)
        let reversed = try await cleanup("please send invoice 4182 to Mara and do not include the draft", url: url)
        XCTAssertEqual(first, reversed)
        XCTAssertTrue(first.contains("4182"))
        let after = await engine.stateForTesting()
        XCTAssertEqual(after.prefixPositions, prepared.prefixPositions)
        let afterDigest = await engine.publicPrefixDigestForTesting()
        XCTAssertEqual(afterDigest, prefixDigest)
        await engine.unload()
        let unloaded = await engine.stateForTesting()
        XCTAssertFalse(unloaded.loaded || unloaded.warmed)
        XCTAssertTrue(unloaded.prefixPositions.isEmpty)
        let readyAfterUnload = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertFalse(readyAfterUnload)
        _ = try await cleanup("Keep invoice 4182 for Mara.", url: url)
        let readyAfterFirstUse = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertTrue(readyAfterFirstUse, "Native first use prepares the runtime without synthetic prewarm")
        await engine.unload()
    }

    func testRealMLXConcurrentRequestsAndCancellationLeaveNextRequestIndependent() async throws {
        let url = try realMLXModel()
        let engine = S1MiniMLXInferenceEngine.shared
        try await engine.prewarm(from: url)
        let before = try await cleanup("what is the capital of France", url: url)
        let tasks = (0..<4).map { index in
            Task { try await cleanup("keep invoice \(8100 + index) and do not change the amount", url: url) }
        }
        for (index, task) in tasks.enumerated() {
            let output = try await task.value
            XCTAssertTrue(output.contains("\(8100 + index)"))
            for other in 0..<4 where other != index { XCTAssertFalse(output.contains("\(8100 + other)")) }
        }
        let long = Task { try await cleanup(String(repeating: "Please keep invoice 8001 unchanged. ", count: 80), url: url) }
        try await Task.sleep(for: .milliseconds(20))
        long.cancel()
        do { _ = try await long.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        let after = try await cleanup("what is the capital of France", url: url)
        XCTAssertEqual(before, after)
        await engine.unload()
    }

    func testRealMLXAllControlsPreserveCacheAndMatchUncachedDecoder() async throws {
        let url = try realMLXModel()
        let engine = S1MiniMLXInferenceEngine.shared
        try await engine.prewarm(from: url)
        let digest = await engine.publicPrefixDigestForTesting()
        for style in S1MiniStyling.allCases {
            for structure in S1MiniStructure.allCases {
                for context: S1MiniContextSetting in [.general, .email] {
                    let text = "please send invoice 4182 to Mara tomorrow and do not include the draft"
                    await engine.configureForTesting(prefix: true)
                    let cached = try await S1MiniPostProcessingService.process(text: text, modelURL: url,
                        styling: style, structure: structure, contextSetting: context, context: nil)
                    await engine.configureForTesting(prefix: false, drafting: false)
                    let fresh = try await S1MiniPostProcessingService.process(text: text, modelURL: url,
                        styling: style, structure: structure, contextSetting: context, context: nil)
                    XCTAssertEqual(cached, fresh, "\(style)/\(structure)/\(context)")
                    XCTAssertTrue(cached.contains("4182") && cached.lowercased().contains("mara"), "\(style)/\(structure)/\(context): \(cached)")
                }
            }
        }
        await engine.configureForTesting(prefix: true)
        let after = await engine.publicPrefixDigestForTesting()
        XCTAssertEqual(after, digest)
        await engine.unload()
    }

    func testRealMLXLongChunkingKeepsEveryNumberAndTheFinalEnding() async throws {
        let url = try realMLXModel()
        let text = (1...110).map { "Please keep invoice \($0) and send the report tomorrow." }.joined(separator: " ")
            + " Do not include the draft."
        let output = try await cleanup(text, url: url)
        let numbers = Set(output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
        XCTAssertEqual(numbers, Set(1...110))
        XCTAssertTrue(output.lowercased().contains("do not include the draft") || output.lowercased().contains("don't include the draft"))
        await S1MiniMLXInferenceEngine.shared.unload()
    }

    private func realMLXModel() throws -> URL {
        let path = ProcessInfo.processInfo.environment["S1_MLX_MODEL_PATH"]
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? S1MiniRuntime.mlx.modelURL(in: S1MiniModelManager.defaultModelDirectory)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["S1_MLX_MODEL_PATH"] != nil,
                          "Set S1_MLX_MODEL_PATH for installed Metal lifecycle tests")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "MLX package not installed")
        try S1MiniModelIntegrity.validate(url)
        return url
    }

    private func cleanup(_ text: String, url: URL) async throws -> String {
        try await S1MiniPostProcessingService.process(text: text, modelURL: url, styling: .semiFormal,
            structure: .prose, contextSetting: .general, context: nil)
    }
    #endif
}

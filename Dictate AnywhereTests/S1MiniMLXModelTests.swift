#if PIPELINE_BENCHMARK
import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniMLXModelTests: XCTestCase {
    override func tearDown() async throws {
        #if DEBUG
        PerfTrace.onIntervalCompleted = nil
        #endif
        #if arch(arm64)
        await S1MiniMLXInferenceEngine.shared.configureForTesting(prefix: true, prefill: 256)
        #endif
        await S1MiniPostProcessingService.unload()
        try await super.tearDown()
    }

    func testRealMLXPrewarmIndependentRequestsAndUnload() async throws {
        #if arch(arm64)
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
        #else
        throw XCTSkip("MLX lifecycle tests require native Apple Silicon")
        #endif
    }

    func testRealMLXConcurrentRequestsAndCancellationLeaveNextRequestIndependent() async throws {
        #if arch(arm64)
        let url = try realMLXModel()
        let engine = S1MiniMLXInferenceEngine.shared
        try await engine.prewarm(from: url)
        let before = try await cleanup("what is the capital of France", url: url)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<4 {
                group.addTask { @MainActor in
                    (index, try await self.cleanup("keep invoice \(8100 + index) and do not change the amount", url: url))
                }
            }
            for try await (index, output) in group {
                XCTAssertTrue(output.contains("\(8100 + index)"))
                for other in 0..<4 where other != index { XCTAssertFalse(output.contains("\(8100 + other)")) }
            }
        }
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await self.cleanup(String(repeating: "Please keep invoice 8001 unchanged. ", count: 80), url: url)
            }
            try await Task.sleep(for: .milliseconds(20))
            group.cancelAll()
            do { _ = try await group.next(); XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        }
        let after = try await cleanup("what is the capital of France", url: url)
        XCTAssertEqual(before, after)
        #else
        throw XCTSkip("MLX lifecycle tests require native Apple Silicon")
        #endif
    }

    func testRealMLXAllControlsPreserveCacheAndMatchUncachedDecoder() async throws {
        #if arch(arm64)
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
                    await engine.configureForTesting(prefix: false)
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
        #else
        throw XCTSkip("MLX lifecycle tests require native Apple Silicon")
        #endif
    }

    func testRealMLXLongChunkingKeepsEveryNumberAndTheFinalEnding() async throws {
        #if arch(arm64)
        let url = try realMLXModel()
        let text = (1...110).map { "Please keep invoice \($0) and send the report tomorrow." }.joined(separator: " ")
            + " Do not include the draft."
        let output = try await cleanup(text, url: url)
        let numbers = Set(output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
        XCTAssertEqual(numbers, Set(1...110))
        XCTAssertTrue(output.lowercased().contains("do not include the draft") || output.lowercased().contains("don't include the draft"))
        #else
        throw XCTSkip("MLX lifecycle tests require native Apple Silicon")
        #endif
    }

    private func realMLXModel() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["S1_MLX_MODEL_PATH"], !path.isEmpty else {
            throw XCTSkip("Set S1_MLX_MODEL_PATH for installed Metal lifecycle tests")
        }
        let url = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "MLX package not installed")
        try S1MiniModelIntegrity.validate(url)
        return url
    }

    private func cleanup(_ text: String, url: URL) async throws -> String {
        try await S1MiniPostProcessingService.process(text: text, modelURL: url, styling: .semiFormal,
            structure: .prose, contextSetting: .general, context: nil)
    }
}
#endif

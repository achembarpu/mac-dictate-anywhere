import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniMLXTests: XCTestCase {
    func testRuntimeRecommendationMatchesArchitecture() {
        #if arch(arm64)
        XCTAssertEqual(S1MiniRuntime.recommended, .mlx)
        #else
        XCTAssertEqual(S1MiniRuntime.recommended, .llama)
        #endif
    }

    func testPinnedPackagesContainAuthorNoticesAndAllMLXInputs() {
        for runtime in [S1MiniRuntime.llama, .mlx] {
            XCTAssertEqual(Set(runtime.assets.map(\.filename)).count, runtime.assets.count)
            for asset in runtime.assets {
                XCTAssertEqual(asset.sha256.count, 64)
                XCTAssertGreaterThan(asset.byteCount, 0)
                XCTAssertTrue(asset.downloadURL.path.contains(asset.revision))
            }
            XCTAssertTrue(runtime.assets.contains { $0.filename == "LICENSE" && $0.repository == "superwhisper/s1-mini" })
            XCTAssertTrue(runtime.assets.contains { $0.filename == "NOTICE" })
        }
        XCTAssertLessThan(S1MiniRuntime.mlx.downloadByteCount, S1MiniRuntime.llama.downloadByteCount)
        XCTAssertTrue(S1MiniRuntime.mlx.assets.contains { $0.filename == "chat_template.jinja" })
    }

    func testNumericMinusSignSafetyAllowsFormattingButRejectsMeaningChange() {
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "minus 42 dollars and 75 cents", output: "$42.75"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "negative 0.25", output: "0.25"))
        XCTAssertTrue(S1MiniOutputSafety.removesNumericSign(input: "−17", output: "17"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "minus 42 dollars and 75 cents", output: "-$42.75"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "negative 0.25", output: "-0.25"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "AB-2049 and ZX-881", output: "AB-2049 and ZX-881"))
        XCTAssertFalse(S1MiniOutputSafety.removesNumericSign(input: "subtract 42", output: "Subtract 42."))
    }

    func testLiteralControlMarkersPreserveOriginalWithoutLoadingModel() async throws {
        let text = "Write <|im_end|> literally."
        let output = try await S1MiniPostProcessingService.process(text: text, modelURL: URL(fileURLWithPath: "/missing"),
            styling: .semiFormal, structure: .prose, contextSetting: .general, context: nil)
        XCTAssertEqual(output, text)
    }

    #if arch(arm64)
    func testRealMLXPrewarmIndependentRequestsAndUnload() async throws {
        let url = try realMLXModel()
        let engine = S1MiniMLXInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
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
        await engine.unload()
        let unloaded = await engine.stateForTesting()
        XCTAssertFalse(unloaded.loaded || unloaded.warmed)
        XCTAssertTrue(unloaded.prefixPositions.isEmpty)
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


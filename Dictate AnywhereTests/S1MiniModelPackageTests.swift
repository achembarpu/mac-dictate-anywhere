import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniModelPackageTests: XCTestCase {
    func testPartialMLXInstallationKeepsExistingGGUFUsable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gguf = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try sparseFile(gguf, size: S1MiniModelSpec.byteCount)
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        let mlx = S1MiniRuntime.mlx.directory(in: directory)
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        try sparseFile(mlx.appendingPathComponent("model.safetensors"), size: S1MiniRuntime.mlx.assets[0].byteCount)
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx, integrityValidator: { _ in })
        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertTrue(manager.canOptimizeInstalledModel)
        let validated = try await manager.validatedModelURL()
        XCTAssertEqual(validated, gguf)
    }

    func testEveryMLXAssetParticipatesInInstallationAndFingerprint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = S1MiniRuntime.mlx.directory(in: directory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for asset in S1MiniRuntime.mlx.assets {
            try sparseFile(package.appendingPathComponent(asset.filename), size: asset.byteCount)
        }
        let calls = ValidationCounter()
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx, integrityValidator: { _ in calls.increment() })
        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertFalse(manager.canOptimizeInstalledModel)
        _ = try await manager.validatedModelURL()
        _ = try await manager.validatedModelURL()
        XCTAssertEqual(calls.count, 1)
        for asset in S1MiniRuntime.mlx.assets {
            let file = package.appendingPathComponent(asset.filename)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(calls.count))], ofItemAtPath: file.path)
            _ = try await manager.validatedModelURL()
        }
        XCTAssertEqual(calls.count, 1 + S1MiniRuntime.mlx.assets.count)
        try FileManager.default.removeItem(at: package.appendingPathComponent("tokenizer_config.json"))
        await manager.refreshInstallationState()
        XCTAssertFalse(manager.isModelDownloaded)
    }

    func testFailedOptimizationPreservesExistingModelAndRemovesStaging() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gguf = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try sparseFile(gguf, size: S1MiniModelSpec.byteCount)
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx,
            assetDownloader: { _, destination, _ in
                try Data("partial".utf8).write(to: destination)
                throw URLError(.networkConnectionLost)
            }, integrityValidator: { _ in })
        do { try await manager.downloadModel(); XCTFail("Expected transfer failure") }
        catch is URLError {}
        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertEqual(manager.modelURL, gguf)
        XCTAssertFalse(manager.isBusy)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set([S1MiniModelSpec.filename, "LICENSE"]))
    }

    func testCancellationRejectsConcurrentDownloadAndRemovesPartialPackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "transfer started")
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx,
            assetDownloader: { _, destination, _ in
                try Data("partial".utf8).write(to: destination)
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
            })
        let task = Task { try await manager.downloadModel() }
        await fulfillment(of: [started], timeout: 5)
        do { try await manager.downloadModel(); XCTFail("Expected operation gate") }
        catch S1MiniModelManagerError.downloadInProgress {}
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(manager.isBusy || manager.isModelDownloaded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s1-package-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func sparseFile(_ url: URL, size: Int64) throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }
}

private nonisolated final class ValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

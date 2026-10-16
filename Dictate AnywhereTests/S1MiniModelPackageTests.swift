import Foundation
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class S1MiniModelPackageTests: XCTestCase {
    func testCorruptPreferredCacheFallsBackOfflineButCancellationDoesNotSwitchModels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gguf = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try sparseFile(gguf, size: S1MiniModelSpec.byteCount)
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        let mlx = S1MiniRuntime.mlx.directory(in: directory)
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        for asset in S1MiniRuntime.mlx.assets {
            try sparseFile(mlx.appendingPathComponent(asset.filename), size: asset.byteCount)
        }
        let managed = S1MiniRuntime.llama.directory(in: directory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        for asset in S1MiniRuntime.llama.assets {
            try sparseFile(managed.appendingPathComponent(asset.filename), size: asset.byteCount)
        }
        for runtime in [S1MiniRuntime.mlx, .llama] {
            for cancelled in [false, true] {
                let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: runtime,
                    integrityValidator: { url in
                        if url != gguf {
                            if cancelled { throw CancellationError() }
                            throw S1MiniModelManagerError.checksumMismatch
                        }
                    })
                if cancelled {
                    do { _ = try await manager.validatedModelURL(); XCTFail("Expected cancellation") }
                    catch is CancellationError {}
                    XCTAssertEqual(manager.modelURL, runtime.modelURL(in: directory))
                } else {
                    let selected = try await manager.validatedModelURL()
                    XCTAssertEqual(selected, gguf)
                    XCTAssertTrue(manager.isModelDownloaded)
                    XCTAssertEqual(manager.canOptimizeInstalledModel, runtime == .mlx)
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: gguf.path))
    }

    func testRealUpgradeWaitsForExistingRequestAndRemovesGGUFOnlyAfterPreparation() async throws {
        let assets = try installedAssets()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        addTeardownBlock { await S1MiniPostProcessingService.unload() }
        let gguf = try installLegacyGGUF(in: directory, source: assets.gguf)
        let managed = S1MiniRuntime.llama.directory(in: directory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: assets.gguf, to: S1MiniRuntime.llama.modelURL(in: directory))
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let downloads = ValidationCounter()
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx,
            assetDownloader: { asset, destination, _ in
                downloads.increment()
                try FileManager.default.copyItem(at: assets.mlx.appendingPathComponent(asset.filename), to: destination)
            })
        let gate = ModelUseGate()
        let started = expectation(description: "existing cleanup holds its installation")
        let existing = Task {
            try await manager.withValidatedModel { url in
                XCTAssertEqual(url, gguf)
                started.fulfill()
                await gate.wait()
                return FileManager.default.fileExists(atPath: url.path)
            }
        }
        await fulfillment(of: [started], timeout: 10)
        let upgrade = Task { try await manager.downloadModel() }
        let deadline = Date().addingTimeInterval(20)
        while manager.downloadProgress < 0.99, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.downloadProgress, 0.99)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gguf.path))
        let queued = Task { try await manager.withValidatedModel { $0 } }
        await gate.release()
        let existingFileSurvived = try await existing.value
        XCTAssertTrue(existingFileSurvived)
        try await upgrade.value
        let nextURL = try await queued.value
        XCTAssertEqual(nextURL, S1MiniRuntime.mlx.modelURL(in: directory))
        XCTAssertEqual(manager.modelURL, nextURL)
        XCTAssertFalse(manager.canOptimizeInstalledModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.gguf.path))
        let prepared = await S1MiniPostProcessingService.isPrepared(modelURL: nextURL)
        XCTAssertTrue(prepared)
        try await manager.downloadModel()
        XCTAssertEqual(downloads.count, S1MiniRuntime.mlx.assets.count, "A completed upgrade must not download again")
        try await manager.deleteModel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.txt"])
    }

    func testRealCachedMLXUpgradeSkipsDownloadsAndRetiresGGUF() async throws {
        let assets = try installedAssets()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        addTeardownBlock { await S1MiniPostProcessingService.unload() }
        let gguf = try installLegacyGGUF(in: directory, source: assets.gguf)
        let mlx = S1MiniRuntime.mlx.directory(in: directory)
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        for asset in S1MiniRuntime.mlx.assets {
            try FileManager.default.copyItem(at: assets.mlx.appendingPathComponent(asset.filename),
                to: mlx.appendingPathComponent(asset.filename))
        }
        let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx,
            assetDownloader: { _, _, _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(manager.canOptimizeInstalledModel)
        try await manager.downloadModel()
        XCTAssertEqual(manager.modelURL, mlx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.path))
        let prepared = await S1MiniPostProcessingService.isPrepared(modelURL: mlx)
        XCTAssertTrue(prepared)
    }

    func testFailedOrCancelledRealUpgradePreparationKeepsOfflineGGUF() async throws {
        let assets = try installedAssets()
        for cancelled in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let gguf = try installLegacyGGUF(in: directory, source: assets.gguf)
            let manager = S1MiniModelManager(modelDirectory: directory, recommendedRuntime: .mlx,
                assetDownloader: { asset, destination, _ in
                    try FileManager.default.copyItem(at: assets.mlx.appendingPathComponent(asset.filename), to: destination)
                }, runtimePreparer: { _ in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: gguf.path))
                    if cancelled { throw CancellationError() }
                    throw S1MiniServiceError.modelLoadFailed
                })
            do { try await manager.downloadModel(); XCTFail("Expected preparation failure") }
            catch is CancellationError { XCTAssertTrue(cancelled) }
            catch S1MiniServiceError.modelLoadFailed { XCTAssertFalse(cancelled) }
            XCTAssertEqual(manager.modelURL, gguf)
            let selected = try await manager.validatedModelURL()
            XCTAssertEqual(selected, gguf)
            XCTAssertTrue(manager.isModelDownloaded && manager.canOptimizeInstalledModel)
            XCTAssertFalse(manager.isBusy)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                Set([S1MiniModelSpec.filename, "LICENSE"]))
        }
    }

    func testRemovingLegacyLicenseInvalidatesPreviouslyVerifiedInstallation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try sparseFile(directory.appendingPathComponent(S1MiniModelSpec.filename), size: S1MiniModelSpec.byteCount)
        let license = directory.appendingPathComponent("LICENSE")
        try Data("license".utf8).write(to: license)
        let manager = S1MiniModelManager(modelDirectory: directory, integrityValidator: { _ in })
        _ = try await manager.validatedModelURL()
        try FileManager.default.removeItem(at: license)
        do { _ = try await manager.validatedModelURL(); XCTFail("License is required") }
        catch S1MiniModelManagerError.missingLicense {}
        XCTAssertFalse(manager.isModelDownloaded)
    }

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

    private func installedAssets() throws -> (mlx: URL, gguf: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let mlx = env["S1_MLX_MODEL_PATH"] else {
            throw XCTSkip("Set S1_MLX_MODEL_PATH for real upgrade checks")
        }
        let gguf = env["S1_MINI_MODEL_PATH"]
            ?? S1MiniModelManager.defaultModelDirectory.appendingPathComponent(S1MiniModelSpec.filename).path
        return (URL(fileURLWithPath: mlx), URL(fileURLWithPath: gguf))
    }

    private func installLegacyGGUF(in directory: URL, source: URL) throws -> URL {
        let gguf = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try FileManager.default.linkItem(at: source, to: gguf)
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        return gguf
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

private actor ModelUseGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if !isOpen { await withCheckedContinuation { waiter = $0 } }
    }

    func release() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private nonisolated final class ValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

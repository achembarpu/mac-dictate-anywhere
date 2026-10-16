//
//  S1MiniModelManager.swift
//  Dictate Anywhere
//
//  Verified download and lifecycle management for S1-mini by Superwhisper.
//

import CryptoKit
import Foundation

enum S1MiniModelManagerError: LocalizedError {
    case downloadInProgress
    case invalidResponse
    case unexpectedFileSize(actual: Int64, expected: Int64)
    case checksumMismatch
    case missingLicense
    case changedDuringValidation

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "An S1-mini model operation is already in progress."
        case .invalidResponse:
            return "The S1-mini download server returned an invalid response."
        case .unexpectedFileSize(let actual, let expected):
            return "The S1-mini download had an unexpected size (\(actual) of \(expected) bytes)."
        case .checksumMismatch:
            return "The S1-mini download failed its integrity check."
        case .missingLicense:
            return "The S1-mini license could not be downloaded."
        case .changedDuringValidation:
            return "The S1-mini model changed while its integrity was being checked."
        }
    }
}

enum S1MiniModelIntegrity {
    nonisolated static func validate(_ url: URL) throws {
        if url.pathExtension == "gguf" {
            if url.deletingLastPathComponent().lastPathComponent == S1MiniRuntime.llama.rawValue {
                for asset in S1MiniRuntime.llama.assets {
                    try validate(url.deletingLastPathComponent().appendingPathComponent(asset.filename), asset: asset)
                }
            } else {
                try validate(url, asset: S1MiniRuntime.llama.assets[0])
            }
        } else {
            for asset in S1MiniRuntime.mlx.assets {
                try validate(url.appendingPathComponent(asset.filename), asset: asset)
            }
        }
    }

    nonisolated static func validate(_ url: URL, asset: S1MiniModelAsset) throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == asset.byteCount else {
            throw S1MiniModelManagerError.unexpectedFileSize(actual: byteCount, expected: asset.byteCount)
        }
        guard try sha256(of: url) == asset.sha256 else {
            throw S1MiniModelManagerError.checksumMismatch
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum S1MiniDownloadProgress {
    nonisolated static let installationFraction = 0.98

    nonisolated static func transferFraction(
        totalBytesWritten: Int64,
        serverExpectedByteCount: Int64,
        pinnedByteCount: Int64 = S1MiniModelSpec.byteCount
    ) -> Double {
        guard pinnedByteCount > 0 else { return 0 }

        // Hugging Face's redirected download may report NSURLSessionTransferSizeUnknown.
        // The pinned artifact size is authoritative and is verified again after download.
        let expectedByteCount = serverExpectedByteCount == pinnedByteCount
            ? serverExpectedByteCount
            : pinnedByteCount
        return min(1, max(0, Double(totalBytesWritten) / Double(expectedByteCount)))
    }

    nonisolated static func installationProgress(
        current: Double,
        transferFraction: Double
    ) -> Double {
        let candidate = min(installationFraction, max(0, transferFraction) * installationFraction)
        return max(current, candidate)
    }
}

private final class S1MiniModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let byteCount: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var activeTask: URLSessionDownloadTask?
    private var cancellationRequested = false
    private var fileMoveError: Error?
    private var lastReportedFraction = -1.0

    init(destinationURL: URL, byteCount: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: .default,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: url)

                stateLock.lock()
                self.continuation = continuation
                activeTask = task
                let shouldCancel = cancellationRequested
                stateLock.unlock()

                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.stateLock.lock()
            self.cancellationRequested = true
            let task = self.activeTask
            self.stateLock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = S1MiniDownloadProgress.transferFraction(
            totalBytesWritten: totalBytesWritten,
            serverExpectedByteCount: totalBytesExpectedToWrite, pinnedByteCount: byteCount
        )

        stateLock.lock()
        let shouldReport = fraction >= 1 || fraction - lastReportedFraction >= 0.002
        if shouldReport {
            lastReportedFraction = fraction
        }
        stateLock.unlock()

        if shouldReport {
            onProgress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            stateLock.lock()
            fileMoveError = error
            stateLock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let pendingContinuation = continuation
        self.continuation = nil
        activeTask = nil
        let pendingFileMoveError = fileMoveError
        self.fileMoveError = nil
        stateLock.unlock()

        session.finishTasksAndInvalidate()
        guard let pendingContinuation else { return }

        if let error {
            pendingContinuation.resume(throwing: error)
        } else if let pendingFileMoveError {
            pendingContinuation.resume(throwing: pendingFileMoveError)
        } else if let response = task.response {
            pendingContinuation.resume(returning: response)
        } else {
            pendingContinuation.resume(throwing: S1MiniModelManagerError.invalidResponse)
        }
    }
}

@Observable
@MainActor
final class S1MiniModelManager {
    nonisolated private struct FileFingerprint: Equatable {
        let path: String
        let byteCount: Int64
        let modificationDate: Date
    }
    private struct InstalledValidation {
        let id: UUID
        let fingerprint: [FileFingerprint]
        let task: Task<Void, Error>
    }

    private(set) var isModelDownloaded = false
    private(set) var isDownloading = false
    private(set) var isDeleting = false
    private(set) var isVerifying = false
    private(set) var runtimeRevision = 0
    private(set) var downloadProgress = 0.0
    private(set) var lastError: String?
    private(set) var installedModelURL: URL?
    let modelDirectory: URL
    let recommendedRuntime: S1MiniRuntime
    private var verifiedFingerprint: [FileFingerprint]?
    @ObservationIgnored private var installedValidation: InstalledValidation?
    @ObservationIgnored private var downloadID: UUID?
    @ObservationIgnored private var changingInstallation = false
    @ObservationIgnored private var activeModelUsers = 0
    @ObservationIgnored private var installationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var usersDrained: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let runtimePreparer: @Sendable (URL) async throws -> Void
    @ObservationIgnored private let assetDownloader: @Sendable (S1MiniModelAsset, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    @ObservationIgnored private let integrityValidator: @Sendable (URL) throws -> Void

    init(
        modelDirectory: URL = S1MiniModelManager.defaultModelDirectory,
        recommendedRuntime: S1MiniRuntime = .recommended,
        assetDownloader: @escaping @Sendable (S1MiniModelAsset, URL, @escaping @Sendable (Double) -> Void) async throws -> Void = S1MiniModelManager.downloadAsset,
        runtimePreparer: @escaping @Sendable (URL) async throws -> Void = S1MiniModelManager.prepareRuntime,
        integrityValidator: @escaping @Sendable (URL) throws -> Void = S1MiniModelIntegrity.validate
    ) {
        self.modelDirectory = modelDirectory
        self.recommendedRuntime = recommendedRuntime
        self.integrityValidator = integrityValidator
        self.assetDownloader = assetDownloader
        self.runtimePreparer = runtimePreparer
        installedModelURL = Self.installedURLs(in: modelDirectory, runtime: recommendedRuntime).first
        isModelDownloaded = installedModelURL != nil
    }

    nonisolated static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Anywhere/Models/S1-mini", isDirectory: true)
    }

    var modelURL: URL { installedModelURL ?? recommendedRuntime.modelURL(in: modelDirectory) }
    var licenseURL: URL { (modelURL.pathExtension == "gguf" ? modelURL.deletingLastPathComponent() : modelURL).appendingPathComponent("LICENSE") }
    var downloadByteCount: Int64 { recommendedRuntime.downloadByteCount }
    var canOptimizeInstalledModel: Bool {
        recommendedRuntime == .mlx && installedModelURL != nil
            && (FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(S1MiniModelSpec.filename).path)
                || FileManager.default.fileExists(atPath: S1MiniRuntime.llama.modelURL(in: modelDirectory).path))
    }
    var installationIdentity: String { installedModelURL?.path ?? "" }
    var isBusy: Bool { isDownloading || isDeleting || isVerifying }

    func refreshInstallationState() async {
        guard !isDownloading, !isDeleting else { return }
        installedModelURL = Self.installedURLs(in: modelDirectory, runtime: recommendedRuntime).first
        guard installedModelURL != nil else {
            isModelDownloaded = false
            verifiedFingerprint = nil
            return
        }
        do {
            _ = try await validatedModelURL()
            lastError = nil
        } catch {
            isModelDownloaded = false
            verifiedFingerprint = nil
            lastError = error.localizedDescription
        }
    }

    func validatedModelURL() async throws -> URL {
        try await validatedModelURL(excluding: [])
    }

    private func validatedModelURL(excluding rejected: Set<URL>) async throws -> URL {
        let trace = PerfTrace.begin("cleanup.validate")
        defer { trace.end() }
        guard let url = installedModelURL else { throw S1MiniServiceError.modelNotDownloaded }
        do {
            let fingerprint = try Self.fingerprint(at: url)
            if fingerprint != verifiedFingerprint {
                try await validateInstalledModel(url: url, fingerprint: fingerprint)
            }
            try Task.checkCancellation()
            isModelDownloaded = true
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            verifiedFingerprint = nil
            isModelDownloaded = false
            // A damaged preferred package must not hide an existing offline GGUF.
            let rejected = rejected.union([url])
            guard installedModelURL == url,
                  let fallback = Self.installedURLs(in: modelDirectory, runtime: recommendedRuntime)
                    .first(where: { !rejected.contains($0) }) else { throw error }
            try Task.checkCancellation()
            installedModelURL = fallback
            return try await validatedModelURL(excluding: rejected)
        }
    }

    /// Hold the selected installation for the entire request, including every
    /// long-input chunk. Upgrade/deletion waits before retiring its files.
    func withValidatedModel<Result>(_ use: (URL) async throws -> Result) async throws -> Result {
        while changingInstallation {
            await withCheckedContinuation { installationWaiters.append($0) }
        }
        try Task.checkCancellation()
        activeModelUsers += 1
        defer {
            activeModelUsers -= 1
            if activeModelUsers == 0 {
                usersDrained?.resume()
                usersDrained = nil
            }
        }
        return try await use(validatedModelURL())
    }

    private func changeInstallation<Result>(_ change: () async throws -> Result) async throws -> Result {
        changingInstallation = true
        defer {
            changingInstallation = false
            let waiting = installationWaiters
            installationWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        if activeModelUsers > 0 {
            await withCheckedContinuation { usersDrained = $0 }
        }
        try Task.checkCancellation()
        return try await change()
    }

    func downloadModel() async throws {
        let trace = PerfTrace.begin("cleanup.modelDownload")
        defer { trace.end() }
        guard !isBusy else { throw S1MiniModelManagerError.downloadInProgress }
        isDownloading = true
        let operationID = UUID()
        downloadID = operationID
        defer { isDownloading = false; downloadID = nil }
        if let url = try? await validatedModelURL() {
            if !canOptimizeInstalledModel {
                lastError = nil
                return
            }
            if url.pathExtension != "gguf" {
                do {
                    try await changeInstallation { try await finishOptimization(at: url, newlyInstalled: false) }
                    downloadProgress = 1
                    lastError = nil
                    return
                } catch {
                    lastError = error.localizedDescription
                    throw error
                }
            }
        }
        try Task.checkCancellation()
        downloadProgress = 0
        lastError = nil
        let fileManager = FileManager.default
        let staging = modelDirectory.appendingPathComponent(".\(UUID()).part", isDirectory: true)
        defer {
            isDownloading = false
            try? fileManager.removeItem(at: staging)
        }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var transferred: Int64 = 0
            for asset in recommendedRuntime.assets {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(asset.filename)
                let completedBytes = transferred
                let totalBytes = downloadByteCount
                try await assetDownloader(asset, destination) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadID == operationID else { return }
                        self.downloadProgress = S1MiniDownloadProgress.installationProgress(current: self.downloadProgress,
                            transferFraction: (Double(completedBytes) + fraction * Double(asset.byteCount)) / Double(totalBytes))
                    }
                }
                try await Task.detached(priority: .utility) {
                    try S1MiniModelIntegrity.validate(destination, asset: asset)
                }.value
                try Task.checkCancellation()
                transferred += asset.byteCount
            }
            downloadProgress = 0.99
            try await changeInstallation {
                runtimeRevision += 1
                await S1MiniPostProcessingService.unload()
                try Task.checkCancellation()
                let destination = recommendedRuntime.directory(in: modelDirectory)
                // Commit a complete, verified package. The old GGUF stays until
                // actual MLX preparation succeeds, including drafted decoding.
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: destination)
                }
                let url = recommendedRuntime.modelURL(in: modelDirectory)
                installedModelURL = url
                verifiedFingerprint = try Self.fingerprint(at: url)
                isModelDownloaded = true
                if canOptimizeInstalledModel {
                    try await finishOptimization(at: url, newlyInstalled: true)
                }
                downloadProgress = 1
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func deleteModel() async throws {
        guard !isBusy else { throw S1MiniModelManagerError.downloadInProgress }
        isDeleting = true
        lastError = nil
        defer { isDeleting = false }
        try await changeInstallation {
            runtimeRevision += 1
            await S1MiniPostProcessingService.unload()
            try Task.checkCancellation()
            let fileManager = FileManager.default
            for runtime in [S1MiniRuntime.llama, .mlx] {
                let directory = runtime.directory(in: modelDirectory)
                if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
            }
            for filename in [S1MiniModelSpec.filename, "LICENSE", "NOTICE"] {
                let url = modelDirectory.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            verifiedFingerprint = nil
            installedModelURL = nil
            isModelDownloaded = false
            downloadProgress = 0
        }
    }

    private func finishOptimization(at url: URL, newlyInstalled: Bool) async throws {
        do {
            try await runtimePreparer(url)
            try Task.checkCancellation()
        } catch {
            await S1MiniPostProcessingService.unload()
            if newlyInstalled { try? FileManager.default.removeItem(at: url) }
            installedModelURL = Self.installedURLs(in: modelDirectory, runtime: .llama).first
            verifiedFingerprint = nil
            isModelDownloaded = installedModelURL != nil
            throw error
        }
        // No request can still hold these files: changeInstallation joins
        // existing users and keeps new requests waiting until selection commits.
        await S1MiniInferenceEngine.shared.unload()
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let managed = S1MiniRuntime.llama.directory(in: modelDirectory)
        if fileManager.fileExists(atPath: managed.path) { try fileManager.removeItem(at: managed) }
        for filename in [S1MiniModelSpec.filename, "LICENSE", "NOTICE"] {
            let legacy = modelDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: legacy.path) { try fileManager.removeItem(at: legacy) }
        }
    }

    nonisolated private static func prepareRuntime(_ url: URL) async throws {
        let ready = await S1MiniPostProcessingService.prewarm(modelURL: url)
        try Task.checkCancellation()
        guard ready else { throw S1MiniServiceError.modelLoadFailed }
    }

    private func validateInstalledModel(url: URL, fingerprint: [FileFingerprint]) async throws {
        let validation: InstalledValidation
        if let inFlight = installedValidation, inFlight.fingerprint == fingerprint {
            validation = inFlight
        } else {
            let validator = integrityValidator
            validation = InstalledValidation(id: UUID(), fingerprint: fingerprint,
                task: Task.detached(priority: .utility) { try validator(url) })
            installedValidation = validation
            isVerifying = true
        }
        defer {
            if installedValidation?.id == validation.id {
                installedValidation = nil
                isVerifying = false
            }
        }
        do {
            try await validation.task.value
            guard installedModelURL == url, try Self.fingerprint(at: url) == fingerprint else {
                throw S1MiniModelManagerError.changedDuringValidation
            }
            verifiedFingerprint = fingerprint
        } catch {
            verifiedFingerprint = nil
            isModelDownloaded = false
            throw error
        }
    }

    nonisolated private static func installedURLs(in root: URL, runtime: S1MiniRuntime) -> [URL] {
        var candidates: [URL] = []
        if complete(runtime.directory(in: root), assets: runtime.assets) {
            candidates.append(runtime.modelURL(in: root))
        }
        if runtime == .mlx, complete(S1MiniRuntime.llama.directory(in: root), assets: S1MiniRuntime.llama.assets) {
            candidates.append(S1MiniRuntime.llama.modelURL(in: root))
        }
        // Existing GGUF downloads remain usable offline until an explicit
        // optimization has verified and prepared their replacement.
        let legacy = root.appendingPathComponent(S1MiniModelSpec.filename)
        if size(legacy) == S1MiniModelSpec.byteCount, size(root.appendingPathComponent("LICENSE")) > 0 {
            candidates.append(legacy)
        }
        return candidates
    }

    nonisolated private static func complete(_ directory: URL, assets: [S1MiniModelAsset]) -> Bool {
        assets.allSatisfy { size(directory.appendingPathComponent($0.filename)) == $0.byteCount }
    }
    nonisolated private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }
    nonisolated private static func fingerprint(at url: URL) throws -> [FileFingerprint] {
        let files: [URL]
        if url.pathExtension != "gguf" {
            files = S1MiniRuntime.mlx.assets.map { url.appendingPathComponent($0.filename) }
        } else if url.deletingLastPathComponent().lastPathComponent == S1MiniRuntime.llama.rawValue {
            files = S1MiniRuntime.llama.assets.map { url.deletingLastPathComponent().appendingPathComponent($0.filename) }
        } else {
            guard size(url.deletingLastPathComponent().appendingPathComponent("LICENSE")) > 0 else {
                throw S1MiniModelManagerError.missingLicense
            }
            files = [url, url.deletingLastPathComponent().appendingPathComponent("LICENSE")]
        }
        return try files.map { file in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return FileFingerprint(path: file.path, byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
                modificationDate: attributes[.modificationDate] as? Date ?? .distantPast)
        }
    }
    nonisolated private static func downloadAsset(
        _ asset: S1MiniModelAsset, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let downloader = S1MiniModelDownloader(destinationURL: destination, byteCount: asset.byteCount, onProgress: progress)
        try requireSuccessfulHTTPResponse(try await downloader.download(from: asset.downloadURL))
    }

    nonisolated private static func requireSuccessfulHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw S1MiniModelManagerError.invalidResponse
        }
    }
}

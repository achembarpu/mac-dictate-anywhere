@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Install only the auxiliary head in the shared application model cache.
/// A failed SDK optional-head load must not silently choose another encoder.
nonisolated enum VocabularyHeadLoader {
    static func load(configuration: MLModelConfiguration,
                     directory: URL = CtcModels.defaultCacheDirectory(for: .ctc110m),
                     progressHandler: ProgressHandler? = nil) async throws -> MLModel {
        try Task.checkCancellation()
        let name = ModelNames.ASR.ctcHeadFile
        let headURL = directory.appendingPathComponent(name)
        let files = FileManager.default
        func isComplete() -> Bool {
            guard files.fileExists(atPath: headURL.appendingPathComponent("coremldata.bin").path),
                  let entries = files.enumerator(at: headURL, includingPropertiesForKeys: nil) else { return false }
            for case let file as URL in entries {
                if file.lastPathComponent.hasSuffix(".partial") { return false }
            }
            return true
        }
        func download() async throws {
            try await ModelHub.download(.parakeetCtc110m, subdirectory: name, to: directory,
                                        progressHandler: progressHandler)
            try Task.checkCancellation()
        }
        if !isComplete() { try await download() }
        progressHandler?(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: name)))
        do {
            let model = try await MLModel.load(contentsOf: headURL, configuration: configuration)
            try Task.checkCancellation()
            return model
        } catch {
            try Task.checkCancellation()
            guard !ModelHub.offlineMode else { throw error }
            // Only a failed local Core ML load reaches this retry. Network
            // failures/cancellation preserve partial files for SDK resumption.
            if files.fileExists(atPath: headURL.path) { try files.removeItem(at: headURL) }
            try await download()
            progressHandler?(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: name)))
            let model = try await MLModel.load(contentsOf: headURL, configuration: configuration)
            try Task.checkCancellation()
            return model
        }
    }
}

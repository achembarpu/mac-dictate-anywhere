import FluidAudio
import Foundation

/// Load the fused speech graphs without the SDK's optional whole-CTC-repo
/// download. Vocabulary preparation installs its own small head when needed.
nonisolated enum CompactSpeechModelLoader {
    static func load(download: Bool) async throws -> AsrModels {
        let directory: URL
        if download { directory = try await AsrModels.download(version: .tdtCtc110m) }
        else { directory = AsrModels.defaultCacheDirectory(for: .tdtCtc110m) }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try AsrModels.loadLocal(from: directory, version: .tdtCtc110m)
        }
        return try await withTaskCancellationHandler {
            let models = try await task.value
            try Task.checkCancellation()
            return models
        } onCancel: { task.cancel() }
    }
}

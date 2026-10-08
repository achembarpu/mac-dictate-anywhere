@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Optional speech detection is installed during explicit setup. Preparing a
/// cached recognizer must never download or repair this shared asset.
nonisolated enum BatchSpeechDetection {
    static var modelURL: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
    }

    static func isDownloaded(at url: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path),
              let contents = files.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        // An interrupted download is not an installed detector.
        for case let item as URL in contents where item.pathExtension == "partial" { return false }
        return true
    }

    private static var config: VadConfig {
        VadConfig(computeUnits: Hardware.canUseAppleNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly)
    }

    static func loadCached(at url: URL) async throws -> VadManager? {
        try Task.checkCancellation()
        guard isDownloaded(at: url) else { return nil }
        let configuration = MLModelConfigurationUtils.defaultConfiguration(computeUnits: config.computeUnits)
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        try Task.checkCancellation()
        return VadManager(config: config, vadModel: model)
    }

    static func download(modelsDirectory: URL) async throws -> VadManager {
        let models = try await ModelHub.loadModels(.vad,
            modelNames: [ModelNames.VAD.sileroVadFile], directory: modelsDirectory,
            computeUnits: config.computeUnits)
        guard let model = models[ModelNames.VAD.sileroVadFile] else { throw VadError.modelLoadingFailed }
        try Task.checkCancellation()
        return VadManager(config: config, vadModel: model)
    }
}

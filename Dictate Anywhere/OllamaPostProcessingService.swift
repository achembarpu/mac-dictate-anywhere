import Foundation
import os

fileprivate actor OllamaModelDetailsCache {
    static let shared = OllamaModelDetailsCache()

    private var values: [String: (date: Date, details: OllamaModelDetails)] = [:]

    func value(for key: String) -> OllamaModelDetails? {
        guard let cached = values[key], Date().timeIntervalSince(cached.date) < 300 else { return nil }
        return cached.details
    }

    func set(_ value: OllamaModelDetails, for key: String) {
        values[key] = (Date(), value)
    }
}

// MARK: - Service

enum OllamaPostProcessingService {
    static let defaultBaseURL = "http://127.0.0.1:11434"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "OllamaPostProcessing"
    )
    struct CLIAvailability: Sendable {
        let executablePath: String?

        var isAvailable: Bool {
            executablePath != nil
        }
    }

    struct Availability: Sendable {
        let installedModels: [String]
        let selectedModel: String
        let resolvedSelectedModel: String?
        let selectedModelReasoningCapability: OllamaReasoningCapability

        var selectedModelIsInstalled: Bool {
            resolvedSelectedModel != nil
        }
    }

    enum ServiceError: LocalizedError {
        case missingModel
        case invalidBaseURL
        case invalidResponse
        case emptyResponse
        case missingCLI
        case serverMessage(String)
        case unexpectedStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingModel:
                return "Enter an installed Ollama model name."
            case .invalidBaseURL:
                return "Enter a valid Ollama server URL."
            case .invalidResponse:
                return "Ollama returned an invalid response."
            case .emptyResponse:
                return "Ollama returned an empty response."
            case .missingCLI:
                return "Install the Ollama CLI to manage models from the app."
            case .serverMessage(let message):
                return message
            case .unexpectedStatus(let status):
                return "Ollama returned HTTP \(status)."
            }
        }
    }

    static func availability(baseURL: String, selectedModel: String) async throws -> Availability {
        let installedModels = try await fetchInstalledModels(baseURL: baseURL)
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedModelNames = installedModels.map(\.name)
        let resolvedSelectedModel = matchingInstalledModel(for: trimmedModel, in: installedModelNames)
        return Availability(
            installedModels: installedModelNames,
            selectedModel: trimmedModel,
            resolvedSelectedModel: resolvedSelectedModel,
            selectedModelReasoningCapability: await selectedModelReasoningCapability(
                baseURL: baseURL,
                selectedModel: trimmedModel,
                resolvedSelectedModel: resolvedSelectedModel
            )
        )
    }

    static func process(
        text: String,
        baseURL: String,
        model: String,
        reasoning: OllamaReasoningSetting = .disabled,
        prompt: String,
        vocabulary: [String] = [],
        context: DictationPostProcessingContext? = nil,
        session: URLSession = .shared
    ) async throws -> String {
        let trace = PerfTrace.begin("cleanup.request")
        defer { trace.end() }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }

        let details = try? await modelDetails(baseURL: baseURL, model: trimmedModel, session: session)
        let contextLength = details?.cleanupContextLength ?? 8_192
        let instructions = remotePostProcessingInstructions(prompt: prompt, vocabulary: vocabulary, context: context)
        var structuredOutput = true
        return try await RemoteCleanupProcessing.process(
            text: text, instructions: instructions, vocabulary: vocabulary, context: context,
            contextLength: contextLength
        ) { chunk in
            for attempt in 0..<2 {
                var request = URLRequest(url: try endpointURL(baseURL: baseURL, endpoint: .generate))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 120
                // Keep model/server sampling defaults. Greedy structured
                // decoding looped on the real Llama long-input benchmark.
                // Bound non-thinking output using the same conservative
                // budget reserved by planning, and reject length completion.
                let outputBudget = TranscriptCleanupPlan.outputReserve(inputTokens: TranscriptCleanupPlan.estimatedTokens(chunk))
                let predictionLimit = details?.isKnownNonThinking == true ? outputBudget : -1
                let options: [String: Any] = ["num_ctx": contextLength, "num_predict": predictionLimit]
                var payload: [String: Any] = [
                    "model": trimmedModel, "system": instructions,
                    "prompt": remotePostProcessingRequestPrompt(text: chunk, vocabulary: vocabulary, context: context),
                    "stream": false, "keep_alive": "10m", "options": options
                ]
                if structuredOutput { payload["format"] = remotePostProcessingOutputSchema }
                if let think = details?.thinkValue(for: reasoning) { payload["think"] = think.jsonValue }
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                do { return try await performGenerateRequest(request, session: session) }
                catch let error as ServiceError {
                    // Ollama Cloud does not currently support schema output.
                    // Adapt only an explicit format rejection; keep the JSON
                    // instructions and validate the naturally completed result.
                    guard case .serverMessage(let message) = error, attempt == 0, structuredOutput,
                          CleanupRequestAdaptation.unsupportedParameter(in: message) == .structuredOutput else { throw error }
                    structuredOutput = false
                }
            }
            throw CleanupResponseError.incompleteResponse
        }
    }

    /// Empty generation loads weights without sending transcript/context text.
    /// Respect the server's offload strategy and use the same bounded context
    /// as the following cleanup request, avoiding a context-size reload.
    static func prewarm(baseURL: String, model: String, session: URLSession = .shared) async -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !Task.isCancelled else { return false }
        do {
            let details = try await modelDetails(baseURL: baseURL, model: model, session: session)
            var request = URLRequest(url: try endpointURL(baseURL: baseURL, endpoint: .generate))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "stream": false, "keep_alive": "10m",
                "options": ["num_ctx": details.cleanupContextLength]
            ])
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let loaded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return loaded.error == nil && loaded.done == true
        } catch { return false }
    }

    static func cliAvailability() -> CLIAvailability {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let candidatePaths = deduplicated([
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ollama").path,
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
        ] + pathEntries.map { "\($0)/ollama" })

        let executablePath = candidatePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        return CLIAvailability(executablePath: executablePath)
    }

    static func isLocalServer(baseURL: String) -> Bool {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return false
        }
        if !normalized.contains("://") {
            normalized = "http://\(normalized)"
        }
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased() else {
            return false
        }

        return ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    }

    static func removeModel(baseURL: String, model: String) async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }

        let availability = cliAvailability()
        guard let executablePath = availability.executablePath else {
            throw ServiceError.missingCLI
        }

        let cliHost = try cliHost(baseURL: baseURL)

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["rm", trimmedModel]

            var environment = ProcessInfo.processInfo.environment
            environment["OLLAMA_HOST"] = cliHost
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                let message = [error, output]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? "Failed to delete \(trimmedModel)."
                throw ServiceError.serverMessage(message)
            }
        }.value
    }

    private enum Endpoint {
        case generate
        case tags
        case show

        var pathSuffix: String {
            switch self {
            case .generate: return "api/generate"
            case .tags: return "api/tags"
            case .show: return "api/show"
            }
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }

        let models: [Model]
    }

    private struct GenerateResponse: Decodable {
        let response: String?
        let thinking: String?
        let done: Bool?
        let doneReason: String?
        let error: String?
        let totalDuration: Int64?
        let loadDuration: Int64?
        let promptEvalCount: Int?
        let promptEvalDuration: Int64?
        let evalCount: Int?
        let evalDuration: Int64?

        enum CodingKeys: String, CodingKey {
            case response
            case thinking
            case done
            case doneReason = "done_reason"
            case error
            case totalDuration = "total_duration"
            case loadDuration = "load_duration"
            case promptEvalCount = "prompt_eval_count"
            case promptEvalDuration = "prompt_eval_duration"
            case evalCount = "eval_count"
            case evalDuration = "eval_duration"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private static func fetchInstalledModels(baseURL: String) async throws -> [TagsResponse.Model] {
        let request = URLRequest(url: try endpointURL(baseURL: baseURL, endpoint: .tags))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        var seen = Set<String>()
        return decoded.models.compactMap { model in
            let trimmedName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, seen.insert(trimmedName).inserted else {
                return nil
            }

            return TagsResponse.Model(name: trimmedName)
        }
    }

    private static func fetchModelDetails(baseURL: String, model: String, session: URLSession = .shared) async throws -> OllamaModelDetails {
        var request = URLRequest(url: try endpointURL(baseURL: baseURL, endpoint: .show))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(OllamaModelDetails.self, from: data)
    }

    private static func performGenerateRequest(_ request: URLRequest, session: URLSession) async throws -> String {
        let (data, response) = try await PerfTrace.measure("cleanup.ollamaRequest") {
            try await session.data(for: request)
        }
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let error = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            throw ServiceError.serverMessage(error)
        }

        guard decoded.done != false, decoded.doneReason == nil || decoded.doneReason == "stop" else {
            throw CleanupResponseError.incompleteResponse
        }
        guard let responseText = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines),
              !responseText.isEmpty else {
            throw ServiceError.emptyResponse
        }

        PerfTrace.event("cleanup.ollamaServerTimings", counts: [
            "total_duration_ns": Int(decoded.totalDuration ?? -1),
            "load_duration_ns": Int(decoded.loadDuration ?? -1),
            "prompt_eval_duration_ns": Int(decoded.promptEvalDuration ?? -1),
            "eval_duration_ns": Int(decoded.evalDuration ?? -1),
            "prompt_eval_count": decoded.promptEvalCount ?? -1,
            "eval_count": decoded.evalCount ?? -1
        ])

        return responseText
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ServiceError.serverMessage(apiError.error)
            }
            throw ServiceError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    private static func endpointURL(baseURL: String, endpoint: Endpoint) throws -> URL {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            throw ServiceError.invalidBaseURL
        }
        if !normalized.contains("://") {
            normalized = "http://\(normalized)"
        }
        guard var components = URLComponents(string: normalized) else {
            throw ServiceError.invalidBaseURL
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch endpoint {
        case .generate:
            if trimmedPath.hasSuffix("api/generate") {
                break
            } else if trimmedPath.hasSuffix("api") {
                components.path = "/" + [trimmedPath, "generate"].joined(separator: "/")
            } else if trimmedPath.isEmpty {
                components.path = "/api/generate"
            } else {
                components.path = "/" + [trimmedPath, "api", "generate"].joined(separator: "/")
            }
        case .tags:
            if trimmedPath.hasSuffix("api/tags") {
                break
            } else if trimmedPath.hasSuffix("api") {
                components.path = "/" + [trimmedPath, "tags"].joined(separator: "/")
            } else if trimmedPath.isEmpty {
                components.path = "/api/tags"
            } else {
                components.path = "/" + [trimmedPath, "api", "tags"].joined(separator: "/")
            }
        case .show:
            if trimmedPath.hasSuffix("api/show") {
                break
            } else if trimmedPath.hasSuffix("api") {
                components.path = "/" + [trimmedPath, "show"].joined(separator: "/")
            } else if trimmedPath.isEmpty {
                components.path = "/api/show"
            } else {
                components.path = "/" + [trimmedPath, "api", "show"].joined(separator: "/")
            }
        }

        guard let url = components.url else {
            throw ServiceError.invalidBaseURL
        }
        return url
    }

    private static func cliHost(baseURL: String) throws -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            throw ServiceError.invalidBaseURL
        }
        if !normalized.contains("://") {
            normalized = "http://\(normalized)"
        }

        guard var components = URLComponents(string: normalized),
              components.host != nil else {
            throw ServiceError.invalidBaseURL
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw ServiceError.invalidBaseURL
        }

        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func matchingInstalledModel(for selectedModel: String, in installedModels: [String]) -> String? {
        guard !selectedModel.isEmpty else { return nil }
        if selectedModel.contains(":") {
            return installedModels.first(where: { $0 == selectedModel })
        }
        return installedModels.first(where: { $0 == selectedModel || $0.hasPrefix("\(selectedModel):") })
    }

    private static func deduplicated(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for model in models {
            if seen.insert(model).inserted {
                ordered.append(model)
            }
        }
        return ordered
    }

    private static func selectedModelReasoningCapability(
        baseURL: String,
        selectedModel: String,
        resolvedSelectedModel: String?
    ) async -> OllamaReasoningCapability {
        let lookupModel = (resolvedSelectedModel ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupModel.isEmpty else { return .unsupported }
        return await reasoningCapability(baseURL: baseURL, model: lookupModel)
    }

    private static func modelDetails(baseURL: String, model: String, session: URLSession = .shared) async throws -> OllamaModelDetails {
        let key = reasoningCapabilityCacheKey(baseURL: baseURL, model: model)
        // Injected transports must not consume or populate production metadata.
        let cachesDetails = session === URLSession.shared
        if cachesDetails, let cached = await OllamaModelDetailsCache.shared.value(for: key) { return cached }
        let details = try await fetchModelDetails(baseURL: baseURL, model: model, session: session)
        if cachesDetails { await OllamaModelDetailsCache.shared.set(details, for: key) }
        return details
    }

    private static func reasoningCapability(baseURL: String, model: String) async -> OllamaReasoningCapability {
        (try? await modelDetails(baseURL: baseURL, model: model))?.reasoningCapability ?? .unsupported
    }

    private static func reasoningCapabilityCacheKey(baseURL: String, model: String) -> String {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedBaseURL)|\(normalizedModel)"
    }
}

import Foundation
import os

enum OpenRouterPostProcessingService {
    static let defaultAPIKeyEnvironmentVariable = "OPENROUTER_API_KEY"
    private static let appAttributionURL = "https://github.com/hoomanaskari/mac-dictate-anywhere"
    private static let appTitle = "Dictate Anywhere"
    private static let dynamicModelVariants: Set<String> = [
        "exacto",
        "floor",
        "nitro",
        "online",
    ]

    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "OpenRouterPostProcessing"
    )

    struct APIKeyStatus: Sendable {
        enum Source: Sendable {
            case storedKey
            case inlineValue
            case environmentVariable
            case missing
        }

        let source: Source
        let environmentVariableName: String

        var isConfigured: Bool {
            source != .missing
        }
    }

    private static var catalog: [Model] = []
    private static var catalogDate: Date?

    struct Model: Identifiable, Hashable, Sendable {
        let id: String
        let supportsStructuredOutputs: Bool
        let supportsAudioInput: Bool
        let supportedParameters: Set<String>?
        let contextLength: Int?
        let maximumCompletionTokens: Int?

        init(id: String, supportsStructuredOutputs: Bool, supportsAudioInput: Bool,
             supportedParameters: Set<String>? = nil, contextLength: Int? = nil, maximumCompletionTokens: Int? = nil) {
            self.id = id; self.supportsStructuredOutputs = supportsStructuredOutputs
            self.supportsAudioInput = supportsAudioInput; self.supportedParameters = supportedParameters
            self.contextLength = contextLength; self.maximumCompletionTokens = maximumCompletionTokens
        }
    }

    struct Availability: Sendable {
        let models: [Model]
        let apiKeyStatus: APIKeyStatus
    }

    enum ServiceError: LocalizedError {
        case missingModel
        case missingAPIKey(String)
        case invalidResponse
        case emptyResponse
        case serverMessage(String)
        case unexpectedStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingModel:
                return "Enter an OpenRouter model name."
            case .missingAPIKey(let environmentVariable):
                return "Paste an OpenRouter API key or set \(environmentVariable) in the app environment."
            case .invalidResponse:
                return "OpenRouter returned an invalid response."
            case .emptyResponse:
                return "OpenRouter returned an empty response."
            case .serverMessage(let message):
                return message
            case .unexpectedStatus(let status):
                return "OpenRouter returned HTTP \(status)."
            }
        }
    }

    static func availability(apiKey: String, apiKeyEnvironmentVariable: String) async throws -> Availability {
        Availability(
            models: try await fetchModels(refresh: true),
            apiKeyStatus: apiKeyStatus(
                apiKey: apiKey,
                apiKeyEnvironmentVariable: apiKeyEnvironmentVariable
            )
        )
    }

    static func apiKeyStatus(apiKey: String, apiKeyEnvironmentVariable: String) -> APIKeyStatus {
        let environmentVariableName = normalizedAPIKeyEnvironmentVariableName(apiKeyEnvironmentVariable)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            return APIKeyStatus(
                source: .storedKey,
                environmentVariableName: environmentVariableName
            )
        }

        let trimmedEnvironmentValue = apiKeyEnvironmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeOpenRouterAPIKey(trimmedEnvironmentValue) {
            return APIKeyStatus(
                source: .inlineValue,
                environmentVariableName: environmentVariableName
            )
        }

        let environmentAPIKey = ProcessInfo.processInfo.environment[environmentVariableName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return APIKeyStatus(
            source: environmentAPIKey.isEmpty ? .missing : .environmentVariable,
            environmentVariableName: environmentVariableName
        )
    }

    static func matchingAvailableModel(for selectedModel: String, in availability: Availability?) -> Model? {
        guard let availability else { return nil }
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        if let exactMatch = availability.models.first(where: {
            $0.id.caseInsensitiveCompare(trimmedModel) == .orderedSame
        }) {
            return exactMatch
        }

        let catalogLookupModel = catalogLookupModelID(for: trimmedModel)
        guard !catalogLookupModel.isEmpty,
              catalogLookupModel.caseInsensitiveCompare(trimmedModel) != .orderedSame else {
            return nil
        }

        return availability.models.first { $0.id.caseInsensitiveCompare(catalogLookupModel) == .orderedSame }
    }

    static func supportsAudioInput(for selectedModel: String, in availability: Availability?) -> Bool {
        matchingAvailableModel(for: selectedModel, in: availability)?.supportsAudioInput ?? false
    }

    static func catalogLookupModelID(for selectedModel: String) -> String {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return "" }

        var components = trimmedModel
            .split(separator: ":")
            .map(String.init)
        while components.count > 1,
              let suffix = components.last?.lowercased(),
              dynamicModelVariants.contains(suffix) {
            components.removeLast()
        }

        return components.joined(separator: ":")
    }

    static func process(
        text: String,
        model: String,
        prompt: String,
        vocabulary: [String] = [],
        apiKey: String,
        apiKeyEnvironmentVariable: String,
        context: DictationPostProcessingContext? = nil,
        session: URLSession = .shared
    ) async throws -> String {
        let trace = PerfTrace.begin("cleanup.request")
        defer { trace.end() }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }

        let apiKey = try resolvedAPIKey(
            apiKey: apiKey,
            apiKeyEnvironmentVariable: apiKeyEnvironmentVariable
        )

        let models = (try? await fetchModels(session: session)) ?? []
        let availability = Availability(models: models, apiKeyStatus: apiKeyStatus(apiKey: apiKey, apiKeyEnvironmentVariable: apiKeyEnvironmentVariable))
        let capabilities = matchingAvailableModel(for: trimmedModel, in: availability)
        let instructions = remotePostProcessingInstructions(prompt: prompt, vocabulary: vocabulary, context: context)
        var options = CleanupChatOptions()
        if let capabilities {
            options.structuredOutput = capabilities.supportedParameters == nil || capabilities.supportsStructuredOutputs
        }
        return try await RemoteCleanupProcessing.process(
            text: text, instructions: instructions, vocabulary: vocabulary, context: context,
            contextLength: capabilities?.contextLength ?? 8_192,
            maximumCompletionTokens: capabilities?.maximumCompletionTokens
        ) { chunk in
            // At most one retry for an explicitly unsupported schema.
            for attempt in 0..<2 {
                do {
                    return try await performChatCompletionRequest(model: trimmedModel, apiKey: apiKey,
                        instructions: instructions,
                        prompt: remotePostProcessingRequestPrompt(text: chunk, vocabulary: vocabulary, context: context),
                        options: options, session: session)
                } catch let error as ServiceError {
                    guard case .serverMessage(let message) = error, attempt == 0, options.adapt(to: message) else { throw error }
                }
            }
            throw CleanupResponseError.incompleteResponse
        }
    }

    /// Catalog/connection preparation only. Cloud weights are provider-managed;
    /// never send a billable dummy completion merely to warm a selected model.
    static func prewarm(model: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        return (try? await fetchModels())?.contains { $0.id == catalogLookupModelID(for: model) } ?? false
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelResponse]
    }

    private struct ModelResponse: Decodable {
        struct ArchitectureResponse: Decodable {
            let inputModalities: [String]?

            enum CodingKeys: String, CodingKey {
                case inputModalities = "input_modalities"
            }
        }

        struct TopProvider: Decodable {
            let contextLength: Int?
            let maxCompletionTokens: Int?
            enum CodingKeys: String, CodingKey { case contextLength = "context_length"; case maxCompletionTokens = "max_completion_tokens" }
        }
        let id: String
        let contextLength: Int?
        let topProvider: TopProvider?
        let supportedParameters: [String]?
        let architecture: ArchitectureResponse?

        enum CodingKeys: String, CodingKey {
            case id
            case contextLength = "context_length"
            case topProvider = "top_provider"
            case supportedParameters = "supported_parameters"
            case architecture
        }
    }

    private struct ErrorResponse: Decodable {
        struct ErrorPayload: Decodable {
            let message: String?
        }

        let error: ErrorPayload?
        let message: String?
    }

    private static func fetchModels(session: URLSession = .shared, refresh: Bool = false) async throws -> [Model] {
        // A custom transport must not read or populate another client's cache.
        let cachesCatalog = session === URLSession.shared
        if cachesCatalog, !refresh, let catalogDate, Date().timeIntervalSince(catalogDate) < 900 { return catalog }
        var request = URLRequest(url: endpointURL(path: "models"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        var seen = Set<String>()

        let models: [Model] = decoded.data.compactMap { model in
            let trimmedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, seen.insert(trimmedID).inserted else {
                return nil
            }

            let supportedParameters = Set((model.supportedParameters ?? []).map { $0.lowercased() })
            let inputModalities = Set((model.architecture?.inputModalities ?? []).map { $0.lowercased() })
            return Model(
                id: trimmedID,
                // response_format alone can mean JSON mode rather than a
                // strict schema. OpenRouter advertises the latter separately.
                supportsStructuredOutputs: supportedParameters.contains("structured_outputs"),
                supportsAudioInput: inputModalities.contains("audio"),
                supportedParameters: model.supportedParameters == nil ? nil : supportedParameters,
                contextLength: [model.contextLength, model.topProvider?.contextLength].compactMap { $0 }.filter { $0 > 0 }.min(),
                maximumCompletionTokens: model.topProvider?.maxCompletionTokens.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        .sorted {
            if $0.supportsStructuredOutputs != $1.supportsStructuredOutputs {
                return $0.supportsStructuredOutputs && !$1.supportsStructuredOutputs
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        if cachesCatalog { catalog = models; catalogDate = Date() }
        return models
    }

    private static func performChatCompletionRequest(
        model: String,
        apiKey: String,
        instructions: String,
        prompt: String,
        options: CleanupChatOptions,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: endpointURL(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(appAttributionURL, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": instructions
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        if options.structuredOutput {
            payload["provider"] = ["require_parameters": true]
            payload["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "dictate_anywhere_cleanup",
                    "strict": true,
                    "schema": remotePostProcessingOutputSchema
                ]
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await PerfTrace.measure("cleanup.openRouterRequest") {
            try await session.data(for: request)
        }
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(CleanupChatCompletion.self, from: data)
        let responseText = try decoded.completeText()

        logger.info(
            "chat completion request kind=transcript-chunk structured_outputs=\(options.structuredOutput, privacy: .public)"
        )

        return responseText
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                let message = apiError.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                if !message.isEmpty {
                    throw ServiceError.serverMessage(message)
                }
            }
            throw ServiceError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    private static func resolvedAPIKey(apiKey: String, apiKeyEnvironmentVariable: String) throws -> String {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            return trimmedAPIKey
        }

        let trimmedEnvironmentValue = apiKeyEnvironmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeOpenRouterAPIKey(trimmedEnvironmentValue) {
            return trimmedEnvironmentValue
        }

        let status = apiKeyStatus(apiKey: "", apiKeyEnvironmentVariable: apiKeyEnvironmentVariable)
        guard case .environmentVariable = status.source,
              let environmentAPIKey = ProcessInfo.processInfo.environment[status.environmentVariableName]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentAPIKey.isEmpty else {
            throw ServiceError.missingAPIKey(status.environmentVariableName)
        }
        return environmentAPIKey
    }

    private static func normalizedAPIKeyEnvironmentVariableName(_ apiKeyEnvironmentVariable: String) -> String {
        let trimmed = apiKeyEnvironmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultAPIKeyEnvironmentVariable : trimmed
    }

    private static func looksLikeOpenRouterAPIKey(_ value: String) -> Bool {
        value.hasPrefix("sk-or-")
    }

    private static func endpointURL(path: String) -> URL {
        baseURL.appending(path: path)
    }
}

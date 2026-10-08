import Foundation
import CryptoKit
import os

enum OpenAICompatiblePostProcessingService {
    static let defaultBaseURL = "http://127.0.0.1:1234/v1"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "OpenAICompatiblePostProcessing"
    )

    nonisolated struct DiscoveryKey: Hashable, Sendable {
        let endpoint: URL
        let credentialID: Data
    }
    private static let discovery = TimedRequestCache<DiscoveryKey, [String]>()
    nonisolated struct SchemaKey: Hashable, Sendable {
        let endpoint: DiscoveryKey
        let model: String
    }
    private static let schemaSupport = CleanupSchemaSupport<SchemaKey>()

    struct Availability: Sendable {
        let models: [String]
        let selectedModel: String

        var selectedModelIsAvailable: Bool {
            models.contains { $0.caseInsensitiveCompare(selectedModel) == .orderedSame }
        }
    }

    enum ServiceError: LocalizedError {
        case missingModel
        case invalidBaseURL
        case invalidResponse
        case emptyResponse
        case serverMessage(String)
        case unexpectedStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingModel:
                return "Enter an OpenAI-compatible model name."
            case .invalidBaseURL:
                return "Enter a valid OpenAI-compatible server URL."
            case .invalidResponse:
                return "The OpenAI-compatible server returned an invalid response."
            case .emptyResponse:
                return "The OpenAI-compatible server returned an empty response."
            case .serverMessage(let message):
                return message
            case .unexpectedStatus(let status):
                return "The OpenAI-compatible server returned HTTP \(status)."
            }
        }
    }

    static func availability(baseURL: String, apiKey: String, selectedModel: String,
                             session: URLSession = .shared,
                             cache: TimedRequestCache<DiscoveryKey, [String]>? = nil) async throws -> Availability {
        Availability(
            models: try await fetchModels(baseURL: baseURL, apiKey: apiKey, refresh: true, session: session, cache: cache ?? (session === URLSession.shared ? discovery : TimedRequestCache())),
            selectedModel: selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func process(
        text: String,
        baseURL: String,
        model: String,
        apiKey: String,
        prompt: String,
        vocabulary: [String] = [],
        context: DictationPostProcessingContext? = nil,
        session: URLSession = .shared,
        schemaSupport: CleanupSchemaSupport<SchemaKey>? = nil
    ) async throws -> String {
        let trace = PerfTrace.begin("cleanup.request")
        defer { trace.end() }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = remotePostProcessingInstructions(prompt: prompt, vocabulary: vocabulary, context: context)
        let key = SchemaKey(endpoint: DiscoveryKey(endpoint: try endpointURL(baseURL: baseURL, path: "chat/completions"),
            credentialID: credentialIdentity(apiKey: trimmedAPIKey)), model: trimmedModel)
        let support = schemaSupport ?? (session === URLSession.shared ? self.schemaSupport : CleanupSchemaSupport())
        return try await RemoteCleanupProcessing.process(
            text: text, instructions: instructions, vocabulary: vocabulary, context: context
        ) { chunk in
            var options = CleanupChatOptions(structuredOutput: await support.usesStructuredOutput(for: key))
            var adaptedSchema = false
            for attempt in 0..<2 {
                do {
                    let output = try await performChatCompletionRequest(baseURL: baseURL, model: trimmedModel,
                        apiKey: trimmedAPIKey, instructions: instructions,
                        prompt: remotePostProcessingRequestPrompt(text: chunk, vocabulary: vocabulary, context: context),
                        options: options, session: session)
                    try Task.checkCancellation()
                    if adaptedSchema { await support.recordUnsupportedSchema(for: key) }
                    return output
                } catch let error as ServiceError {
                    guard case .serverMessage(let message) = error, attempt == 0, options.adapt(to: message) else { throw error }
                    adaptedSchema = true
                }
            }
            throw CleanupResponseError.incompleteResponse
        }
    }

    static func prewarm(baseURL: String, model: String, apiKey: String,
                        refresh: Bool = false, session: URLSession = .shared,
                        cache: TimedRequestCache<DiscoveryKey, [String]>? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        // The portable API has no model-load operation. Prepare the connection
        // and discover models without generating or sharing transcript/context.
        return (try? await fetchModels(baseURL: baseURL, apiKey: apiKey, refresh: refresh, session: session, cache: cache ?? (session === URLSession.shared ? discovery : TimedRequestCache())))?.contains {
            $0.caseInsensitiveCompare(model) == .orderedSame
        } ?? false
    }

    nonisolated private struct ModelsResponse: Decodable {
        let data: [ModelResponse]
    }

    nonisolated private struct ModelResponse: Decodable {
        let id: String
    }

    nonisolated private struct ErrorResponse: Decodable {
        nonisolated struct ErrorPayload: Decodable {
            let message: String?
        }

        nonisolated enum ErrorValue: Decodable {
            case text(String)
            case payload(ErrorPayload)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .text(string)
                    return
                }
                if let payload = try? container.decode(ErrorPayload.self) {
                    self = .payload(payload)
                    return
                }
                throw DecodingError.typeMismatch(
                    ErrorValue.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unsupported error payload."
                    )
                )
            }

            var message: String? {
                switch self {
                case .text(let value):
                    return value
                case .payload(let payload):
                    return payload.message
                }
            }
        }

        let error: ErrorValue?
        let message: String?
    }

    private static func fetchModels(baseURL: String, apiKey: String, refresh: Bool,
                                    session: URLSession, cache: TimedRequestCache<DiscoveryKey, [String]>) async throws -> [String] {
        let credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = DiscoveryKey(endpoint: try endpointURL(baseURL: baseURL, path: "models"),
                               credentialID: credentialIdentity(apiKey: credential))
        return try await cache.value(for: key, refresh: refresh) {
            try await fetchModelsUncached(endpoint: key.endpoint, apiKey: credential, session: session)
        }
    }

    /// Cache identity must separate authenticated catalogs without retaining keys.
    nonisolated static func credentialIdentity(apiKey: String) -> Data {
        Data(SHA256.hash(data: Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
    }

    nonisolated private static func fetchModelsUncached(endpoint: URL, apiKey: String,
                                                       session: URLSession) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        var seen = Set<String>()
        return decoded.data.compactMap { model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func performChatCompletionRequest(
        baseURL: String,
        model: String,
        apiKey: String,
        instructions: String,
        prompt: String,
        options: CleanupChatOptions,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: try endpointURL(baseURL: baseURL, path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

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

        let (data, response) = try await PerfTrace.measure("cleanup.openAICompatibleRequest") {
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

    nonisolated private static func validate(response: URLResponse, data: Data) throws {
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

    private static func endpointURL(baseURL: String, path: String) throws -> URL {
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

        let requestedComponents = path
            .split(separator: "/")
            .map(String.init)
        var pathComponents = components.path
            .split(separator: "/")
            .map(String.init)

        if hasSuffix(pathComponents, requestedComponents) {
            return try finalizedURL(from: components)
        }

        if pathComponents.last?.caseInsensitiveCompare("v1") != .orderedSame {
            pathComponents.append("v1")
        }
        pathComponents.append(contentsOf: requestedComponents)
        components.path = "/" + pathComponents.joined(separator: "/")
        return try finalizedURL(from: components)
    }

    private static func finalizedURL(from components: URLComponents) throws -> URL {
        guard let url = components.url else {
            throw ServiceError.invalidBaseURL
        }
        return url
    }

    private static func hasSuffix(_ values: [String], _ suffix: [String]) -> Bool {
        guard values.count >= suffix.count else { return false }
        return zip(values.suffix(suffix.count), suffix).allSatisfy {
            $0.0.caseInsensitiveCompare($0.1) == .orderedSame
        }
    }
}

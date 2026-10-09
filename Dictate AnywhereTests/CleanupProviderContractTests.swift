import Foundation
import os
import XCTest
@testable import Dictate_Anywhere

private final class CleanupHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated static let handler = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> (Int, Data))?>(initialState: nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.handler.withLock { $0 }
            let (status, data) = try XCTUnwrap(callback)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class CleanupProviderContractTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CleanupHTTPStub.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        CleanupHTTPStub.handler.withLock { $0 = nil }
    }

    nonisolated private static func payload(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPortableDiscoveryCachesPrewarmButRefreshesExplicitChecksAndSeparatesCredentials() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            calls.withLock { $0.append((request.url?.absoluteString ?? "") + " " + (request.value(forHTTPHeaderField: "Authorization") ?? "")) }
            return (200, Data(#"{"data":[{"id":" model "},{"id":"model"},{"id":""}]}"#.utf8))
        } }
        let cache = TimedRequestCache<OpenAICompatiblePostProcessingService.DiscoveryKey, [String]>()
        for _ in 0..<3 {
            let ready = await OpenAICompatiblePostProcessingService.prewarm(baseURL: "http://cleanup.test/v1/", model: "model",
                apiKey: " first ", session: session, cache: cache)
            XCTAssertTrue(ready)
        }
        XCTAssertEqual(calls.withLock { $0.count }, 1)
        let availability = try await OpenAICompatiblePostProcessingService.availability(baseURL: "http://cleanup.test/v1", apiKey: "first",
            selectedModel: "model", session: session, cache: cache)
        XCTAssertEqual(availability.models, ["model"])
        XCTAssertEqual(calls.withLock { $0.count }, 2, "An explicit readiness check must fetch current models")
        _ = await OpenAICompatiblePostProcessingService.prewarm(baseURL: "http://cleanup.test/v1", model: "model",
            apiKey: "second", session: session, cache: cache)
        _ = await OpenAICompatiblePostProcessingService.prewarm(baseURL: "http://other.test/v1", model: "model",
            apiKey: "second", session: session, cache: cache)
        XCTAssertEqual(calls.withLock { $0.count }, 4)
        XCTAssertTrue(calls.withLock { $0[2].hasSuffix("Bearer second") })
    }

    func testPortableDiscoveryDoesNotCacheFailuresOrExpiredResults() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        CleanupHTTPStub.handler.withLock { $0 = { _ in
            let count = calls.withLock { $0 += 1; return $0 }
            return count == 1 ? (503, Data()) : (200, Data(#"{"data":[{"id":"model"}]}"#.utf8))
        } }
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let cache = TimedRequestCache<OpenAICompatiblePostProcessingService.DiscoveryKey, [String]>(
            lifetime: .seconds(60), now: { clock.withLock { $0 } })
        var readiness: [Bool] = []
        for _ in 0..<3 {
            readiness.append(await OpenAICompatiblePostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
                apiKey: "", session: session, cache: cache))
        }
        XCTAssertEqual(readiness, [false, true, true])
        XCTAssertEqual(calls.withLock { $0 }, 2, "Failure must retry while success remains fresh")
        clock.withLock { $0 = $0.advanced(by: .seconds(61)) }
        let expired = await OpenAICompatiblePostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
            apiKey: "", session: session, cache: cache)
        XCTAssertTrue(expired)
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testConcurrentDiscoverySharesOneInFlightRequest() async throws {
        let cache = TimedRequestCache<String, Int>(lifetime: .zero)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let load: @Sendable () async throws -> Int = {
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(100))
            return 42
        }
        async let first = cache.value(for: "same", load: load)
        async let second = cache.value(for: "same", load: load)
        let results = try await [first, second]
        XCTAssertEqual(results, [42, 42])
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testOllamaSharesMetadataAndPreloadAcrossLatestAliasAndForcesRefresh() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String: Int]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            let path = try XCTUnwrap(request.url?.path)
            requests.withLock { $0[path, default: 0] += 1 }
            if path.hasSuffix("show") {
                return (200, Data(#"{"model_info":{"llama.context_length":131072}}"#.utf8))
            }
            let payload = try Self.payload(request)
            XCTAssertNil(payload["prompt"])
            XCTAssertNil(payload["system"])
            XCTAssertEqual((payload["options"] as? [String: Int])?["num_ctx"], 8_192)
            return (200, Data(#"{"done":true}"#.utf8))
        } }
        let details = TimedRequestCache<OllamaPostProcessingService.DetailsKey, OllamaModelDetails>()
        let preloads = TimedRequestCache<OllamaPostProcessingService.PreloadKey, Bool>()
        for model in ["model", "model:latest", "model"] {
            let ready = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: model,
                session: session, detailsCache: details, preloadCache: preloads)
            XCTAssertTrue(ready)
        }
        XCTAssertEqual(requests.withLock { $0["/api/show"] }, 1)
        XCTAssertEqual(requests.withLock { $0["/api/generate"] }, 1)
        let refreshed = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
            refresh: true, session: session, detailsCache: details, preloadCache: preloads)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(requests.withLock { $0["/api/show"] }, 2)
        XCTAssertEqual(requests.withLock { $0["/api/generate"] }, 2)
        for (base, model) in [("http://other.test", "model"), ("http://cleanup.test", "other")] {
            let ready = await OllamaPostProcessingService.prewarm(baseURL: base, model: model,
                session: session, detailsCache: details, preloadCache: preloads)
            XCTAssertTrue(ready)
        }
        XCTAssertEqual(requests.withLock { $0["/api/generate"] }, 4)
    }

    func testOllamaPreloadFailuresAreRetriedAndExpiredResidencyIsReloaded() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fail = OSAllocatedUnfairLock(initialState: true)
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("show") == true { return (200, Data(#"{}"#.utf8)) }
            calls.withLock { $0 += 1 }
            return (200, Data((fail.withLock { $0 } ? #"{"done":false}"# : #"{"done":true}"#).utf8))
        } }
        let details = TimedRequestCache<OllamaPostProcessingService.DetailsKey, OllamaModelDetails>()
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let preloads = TimedRequestCache<OllamaPostProcessingService.PreloadKey, Bool>(
            lifetime: .seconds(60), now: { clock.withLock { $0 } })
        for _ in 0..<2 {
            let ready = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
                session: session, detailsCache: details, preloadCache: preloads)
            XCTAssertFalse(ready)
        }
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            let ready = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
                session: session, detailsCache: details, preloadCache: preloads)
            XCTAssertTrue(ready)
        }
        XCTAssertEqual(calls.withLock { $0 }, 3, "Failed preload retries; successful residency is shared")
        clock.withLock { $0 = $0.advanced(by: .seconds(61)) }
        let expired = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: "model",
            session: session, detailsCache: details, preloadCache: preloads)
        XCTAssertTrue(expired)
        XCTAssertEqual(calls.withLock { $0 }, 4)
    }

    func testOpenRouterCatalogSharesPrewarmAndRefreshesWithoutGenerating() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        CleanupHTTPStub.handler.withLock { $0 = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/models")
            XCTAssertNil(request.httpBody)
            calls.withLock { $0 += 1 }
            return (200, Data(#"{"data":[{"id":"test/model"}]}"#.utf8))
        } }
        let cache = TimedRequestCache<URL, [OpenRouterPostProcessingService.Model]>()
        for _ in 0..<3 {
            let ready = await OpenRouterPostProcessingService.prewarm(model: "test/model",
                session: session, cache: cache)
            XCTAssertTrue(ready)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let refreshed = await OpenRouterPostProcessingService.prewarm(model: "test/model",
            refresh: true, session: session, cache: cache)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testOllamaPreloadContainsNoTranscriptAndGenerationKeepsModelPreset() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        CleanupHTTPStub.handler.withLock { callback in
            callback = { request in
                let payload = try Self.payload(request)
                if request.url?.path.hasSuffix("show") == true {
                    return (200, Data(#"{"thinking":{"values":[true],"default":true},"parameters":"temperature 0.6\ntop_p 0.95","model_info":{"qwen3.context_length":262144}}"#.utf8))
                }
                requests.withLock { $0.append(payload) }
                if payload["prompt"] == nil { return (200, Data(#"{"done":true,"done_reason":"load","response":""}"#.utf8)) }
                return (200, Data(#"{"done":true,"done_reason":"stop","response":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}"#.utf8))
            }
        }
        let model = UUID().uuidString
        let warm = await OllamaPostProcessingService.prewarm(baseURL: "http://cleanup.test", model: model, session: session)
        XCTAssertTrue(warm)
        let output = try await OllamaPostProcessingService.process(text: "hello", baseURL: "http://cleanup.test", model: model,
            prompt: "Correct punctuation.", session: session)
        XCTAssertEqual(output, "Hello.")
        let payloads = requests.withLock { $0 }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertNil(payloads[0]["system"])
        XCTAssertNil(payloads[0]["prompt"])
        let options = try XCTUnwrap(payloads[1]["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 8_192)
        XCTAssertEqual(options["num_predict"] as? Int, -1)
        XCTAssertNil(options["temperature"], "Do not override a curated model sampling preset")
        XCTAssertNil(payloads[1]["think"], "Cannot turn off mandatory thinking")
        let schema = try XCTUnwrap(payloads[1]["format"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testPortableServerRetriesOnlyExplicitUnsupportedSchema() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        CleanupHTTPStub.handler.withLock { callback in
            callback = { request in
                let payload = try Self.payload(request)
                requests.withLock { $0.append(payload) }
                if payload["response_format"] != nil {
                    return (400, Data(#"{"error":{"message":"response_format json_schema is not supported"}}"#.utf8))
                }
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}}]}"#.utf8))
            }
        }
        let output = try await OpenAICompatiblePostProcessingService.process(text: "hello", baseURL: "http://cleanup.test/v1",
            model: "model", apiKey: "", prompt: "Correct punctuation.", session: session)
        XCTAssertEqual(output, "Hello.")
        let payloads = requests.withLock { $0 }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertNotNil(payloads[0]["response_format"])
        XCTAssertNil(payloads[1]["response_format"])
        XCTAssertTrue(payloads.allSatisfy { $0["temperature"] == nil }, "Unknown model sampling belongs to its server")
    }

    func testPortableRemembersConfirmedSchemaRejectionAndScopesItToEndpointModelAndCredential() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [Bool]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            let schema = try Self.payload(request)["response_format"] != nil
            requests.withLock { $0.append(schema) }
            return schema ? (400, Data(#"{"error":{"message":"response_format json_schema is not supported"}}"#.utf8))
                : (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}}]}"#.utf8))
        } }
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let support = CleanupSchemaSupport<OpenAICompatiblePostProcessingService.SchemaKey>(
            lifetime: .seconds(60), now: { clock.withLock { $0 } })
        for (base, model, key) in [("http://cleanup.test", "model", "first"), ("http://cleanup.test/v1/", "model", " first "),
                                   ("http://other.test", "model", "first"), ("http://cleanup.test", "other", "first"),
                                   ("http://cleanup.test", "model", "second")] {
            let output = try await OpenAICompatiblePostProcessingService.process(text: "hello", baseURL: base,
                model: model, apiKey: key, prompt: "Correct punctuation.", session: session, schemaSupport: support)
            XCTAssertEqual(output, "Hello.")
        }
        XCTAssertEqual(requests.withLock { $0 }, [true, false, false, true, false, true, false, true, false])
        clock.withLock { $0 = $0.advanced(by: .seconds(61)) }
        _ = try await OpenAICompatiblePostProcessingService.process(text: "hello", baseURL: "http://cleanup.test", model: "model",
            apiKey: "first", prompt: "Correct punctuation.", session: session, schemaSupport: support)
        XCTAssertEqual(requests.withLock { Array($0.suffix(2)) }, [true, false], "Expiry probes support again")
    }

    func testFailedUnstructuredRetryDoesNotTeachSchemaSupport() async throws {
        let schemas = OSAllocatedUnfairLock(initialState: [Bool]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            let schema = try Self.payload(request)["response_format"] != nil
            schemas.withLock { $0.append(schema) }
            return schema ? (400, Data(#"{"error":{"message":"response_format is not supported"}}"#.utf8)) : (503, Data())
        } }
        let support = CleanupSchemaSupport<OpenAICompatiblePostProcessingService.SchemaKey>()
        for _ in 0..<2 {
            do {
                _ = try await OpenAICompatiblePostProcessingService.process(text: "hello", baseURL: "http://cleanup.test", model: "model",
                    apiKey: "", prompt: "Correct punctuation.", session: session, schemaSupport: support)
                XCTFail("Unavailable cleanup must fail")
            } catch { XCTAssertTrue(error is OpenAICompatiblePostProcessingService.ServiceError) }
        }
        XCTAssertEqual(schemas.withLock { $0 }, [true, false, true, false])
    }

    func testOllamaRemembersConfirmedFormatRejectionAcrossLatestAlias() async throws {
        let schemas = OSAllocatedUnfairLock(initialState: [Bool]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("show") == true { return (200, Data(#"{}"#.utf8)) }
            let schema = try Self.payload(request)["format"] != nil
            schemas.withLock { $0.append(schema) }
            return schema ? (400, Data(#"{"error":"format is not supported for cloud models"}"#.utf8))
                : (200, Data(#"{"done":true,"done_reason":"stop","response":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}"#.utf8))
        } }
        let support = CleanupSchemaSupport<OllamaPostProcessingService.DetailsKey>()
        for model in ["model", "model:latest", "other"] {
            let output = try await OllamaPostProcessingService.process(text: "hello", baseURL: "http://cleanup.test", model: model,
                prompt: "Correct punctuation.", session: session, schemaSupport: support)
            XCTAssertEqual(output, "Hello.")
        }
        XCTAssertEqual(schemas.withLock { $0 }, [true, false, false, true, false])
    }

    func testOllamaNonThinkingBudgetAndTransportMetadataAreIsolated() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        let discoveries = OSAllocatedUnfairLock(initialState: 0)
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("show") == true {
                let discovery = discoveries.withLock { $0 += 1; return $0 }
                let limit = discovery == 1 ? 4_096 : 8_192
                let metadata = discovery == 1 ? #""thinking":{"values":[false]}"# : #""capabilities":["completion","tools"]"#
                return (200, Data("{\(metadata),\"model_info\":{\"llama.context_length\":\(limit)}}".utf8))
            }
            let payload = try Self.payload(request)
            requests.withLock { $0.append(payload) }
            return (200, Data(#"{"done":true,"done_reason":"stop","response":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}"#.utf8))
        } }
        let model = UUID().uuidString
        for _ in 0..<2 {
            _ = try await OllamaPostProcessingService.process(text: "hello", baseURL: "http://cleanup.test",
                model: model, prompt: "Correct punctuation.", session: session)
        }
        let payloads = requests.withLock { $0 }
        XCTAssertEqual(discoveries.withLock { $0 }, 2)
        for (index, payload) in payloads.enumerated() {
            let options = try XCTUnwrap(payload["options"] as? [String: Any])
            XCTAssertEqual(options["num_ctx"] as? Int, index == 0 ? 4_096 : 8_192)
            XCTAssertEqual(options["num_predict"] as? Int, TranscriptCleanupPlan.outputReserve(inputTokens: 5))
            XCTAssertNil(options["temperature"], "Preserve server defaults even without an author preset")
            XCTAssertNil(payload["think"], "Default On preserves the provider recommendation, including non-thinking models")
        }
    }

    func testOpenRouterUsesCatalogDefaultsAndRequiresSchemaCapableRouting() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("models") == true {
                return (200, Data(#"{"data":[{"id":"test/curated","context_length":16384,"supported_parameters":["temperature","structured_outputs"],"default_parameters":{"temperature":0.7},"top_provider":{"context_length":8192,"max_completion_tokens":4096}},{"id":"test/json-only","context_length":8192,"supported_parameters":["response_format"],"reasoning":{"mandatory":true}}]}"#.utf8))
            }
            let payload = try Self.payload(request)
            requests.withLock { $0.append(payload) }
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}}]}"#.utf8))
        } }
        let output = try await OpenRouterPostProcessingService.process(text: "hello", model: "test/curated",
            prompt: "Correct punctuation.", apiKey: "contract-test-key", apiKeyEnvironmentVariable: "",
            session: session)
        XCTAssertEqual(output, "Hello.")
        let payload = try XCTUnwrap(requests.withLock { $0.first })
        XCTAssertNil(payload["temperature"])
        XCTAssertNotNil(payload["response_format"])
        XCTAssertEqual((payload["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        _ = try await OpenRouterPostProcessingService.process(text: "hello", model: "test/json-only",
            prompt: "Correct punctuation.", apiKey: "contract-test-key", apiKeyEnvironmentVariable: "", session: session)
        let jsonOnly = try XCTUnwrap(requests.withLock { $0.last })
        XCTAssertNil(jsonOnly["temperature"])
        XCTAssertNil(jsonOnly["response_format"], "JSON mode support does not establish strict-schema support")
        XCTAssertNil(jsonOnly["provider"])
    }

    func testOpenRouterPreservesProviderReasoningByDefaultAndDisablesOnlyWhenAllowed() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        let catalog = Data(#"""
        {"data":[
          {
            "id":"test/flexible",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"supported_efforts":["minimal","low"],"mandatory":false}
          },
          {
            "id":"test/explicit-none",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"supported_efforts":["none","minimal"],"mandatory":false}
          },
          {
            "id":"test/required",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"supported_efforts":["low","minimal"],"mandatory":true}
          },
          {
            "id":"test/required-any",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"supported_efforts":null,"mandatory":true}
          },
          {
            "id":"test/required-default",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"mandatory":true}
          },
          {
            "id":"test/already-off",
            "supported_parameters":["structured_outputs"],
            "reasoning":{"supported_efforts":["minimal"],"mandatory":false}
          },
          {"id":"test/unknown","supported_parameters":["structured_outputs"]},
          {"id":"test/malformed","supported_parameters":["structured_outputs"],"reasoning":"future shape"}
        ]}
        """#.utf8)
        let completion = Data(#"""
        {
          "choices":[
            {
              "finish_reason":"stop",
              "message":{"content":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}
            }
          ]
        }
        """#.utf8)
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("models") == true {
                return (200, catalog)
            }
            let payload = try Self.payload(request)
            requests.withLock { $0.append(payload) }
            return (200, completion)
        } }

        for (model, setting) in [
            ("test/flexible", true),
            ("test/flexible", false),
            ("test/explicit-none", false),
            ("test/required", true),
            ("test/required", false),
            ("test/required-any", false),
            ("test/required-default", false),
            ("test/already-off", true),
            ("test/already-off", false),
            ("test/unknown", false),
            ("test/malformed", false),
            ("test/flexible:floor", false),
        ] {
            _ = try await OpenRouterPostProcessingService.process(
                text: "hello", model: model, prompt: "Correct punctuation.",
                apiKey: "contract-test-key", apiKeyEnvironmentVariable: "",
                reasoningEnabled: setting, session: session
            )
        }

        let payloads = requests.withLock { $0 }
        XCTAssertEqual(payloads.count, 12)
        XCTAssertNil(payloads[0]["reasoning"], "On should preserve the provider's recommended reasoning setting")
        XCTAssertEqual((payloads[1]["reasoning"] as? [String: Any])?["enabled"] as? Bool, false,
                       "Off should disable reasoning when the catalog says it is optional")
        XCTAssertEqual((payloads[2]["reasoning"] as? [String: Any])?["effort"] as? String, "none",
                       "Off should use the advertised none effort when supported")
        XCTAssertNil(payloads[3]["reasoning"], "On should leave mandatory model effort to the provider")
        XCTAssertNil(payloads[4]["reasoning"], "Off must not override a model that requires reasoning")
        XCTAssertNil(payloads[5]["reasoning"], "An explicit null effort list does not allow disabling mandatory reasoning")
        XCTAssertNil(payloads[6]["reasoning"], "Missing effort controls on a mandatory model preserve provider behavior")
        XCTAssertNil(payloads[7]["reasoning"], "On should preserve a model default that already has reasoning off")
        XCTAssertEqual((payloads[8]["reasoning"] as? [String: Any])?["enabled"] as? Bool, false,
                       "Off should remain safe for explicitly optional reasoning even when default is off")
        XCTAssertNil(payloads[9]["reasoning"], "Unknown capabilities must never receive a guessed reasoning override")
        XCTAssertNotNil(
            payloads[10]["response_format"],
            "Malformed optional reasoning metadata must not discard the catalog's other capabilities"
        )
        XCTAssertNil(payloads[10]["reasoning"], "Malformed optional reasoning metadata must not enable request controls")
        XCTAssertNil(payloads[11]["reasoning"], "Dynamic routing variants must not inherit a base model's reasoning controls")
    }

    func testOllamaRetriesExplicitCloudFormatRejectionOnce() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("show") == true { return (200, Data(#"{}"#.utf8)) }
            let payload = try Self.payload(request)
            requests.withLock { $0.append(payload) }
            if payload["format"] != nil { return (400, Data(#"{"error":"format is not supported for cloud models"}"#.utf8)) }
            return (200, Data(#"{"done":true,"done_reason":"stop","response":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}"#.utf8))
        } }
        let output = try await OllamaPostProcessingService.process(text: "hello", baseURL: "http://cleanup.test",
            model: UUID().uuidString, prompt: "Correct punctuation.", session: session)
        XCTAssertEqual(output, "Hello.")
        XCTAssertEqual(requests.withLock { $0.count }, 2)
        XCTAssertNil(requests.withLock { $0.last?["format"] })
    }

    func testPortableServerDoesNotRetryQuotaOrContextErrorsOrReturnPartialCompletion() async throws {
        for (status, body) in [
            (400, #"{"error":{"message":"context length exceeded"}}"#),
            (401, #"{"error":{"message":"invalid authentication"}}"#),
            (429, #"{"error":{"message":"quota exceeded"}}"#),
            (200, #"{"choices":[{"finish_reason":"length","message":{"content":"partial prefix"}}]}"#)
        ] {
            let count = OSAllocatedUnfairLock(initialState: 0)
            CleanupHTTPStub.handler.withLock { $0 = { _ in
                count.withLock { $0 += 1 }
                return (status, Data(body.utf8))
            } }
            do {
                _ = try await OpenAICompatiblePostProcessingService.process(text: "keep all details", baseURL: "http://cleanup.test",
                    model: "model", apiKey: "", prompt: "Clean punctuation.", session: session)
                XCTFail("Should preserve the original through the caller's error path")
            } catch {}
            XCTAssertEqual(count.withLock { $0 }, 1)
        }
    }

    func testAnyFailedChunkPreventsReturningASuccessfulPrefix() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let text = String(repeating: "Keep the report and its appendix.\n", count: 60)
        do {
            _ = try await RemoteCleanupProcessing.process(text: text, instructions: "Clean punctuation.", vocabulary: [], context: nil,
                contextLength: 1_200) { chunk in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 2 { throw CleanupResponseError.incompleteResponse }
                let data = try JSONSerialization.data(withJSONObject: ["action": "pasteCleanedText", "text": chunk])
                return String(decoding: data, as: UTF8.self)
            }
            XCTFail("A later failure must not return only the successful first part")
        } catch { XCTAssertTrue(error is CleanupResponseError) }
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testGenericFormatErrorsDoNotRetryPortableOrOllamaGeneration() async throws {
        for message in ["unsupported model file format", "audio format is not supported", "unsupported information format"] {
            for useOllama in [false, true] {
                let generations = OSAllocatedUnfairLock(initialState: 0)
                CleanupHTTPStub.handler.withLock { $0 = { request in
                    if request.url?.path.hasSuffix("show") == true { return (200, Data(#"{}"#.utf8)) }
                    generations.withLock { $0 += 1 }
                    let error: [String: Any] = useOllama
                        ? ["error": message]
                        : ["error": ["message": message]]
                    return (400, try JSONSerialization.data(withJSONObject: error))
                } }
                do {
                    if useOllama {
                        _ = try await OllamaPostProcessingService.process(text: "keep all details", baseURL: "http://cleanup.test",
                            model: UUID().uuidString, prompt: "Clean punctuation.", session: session)
                    } else {
                        _ = try await OpenAICompatiblePostProcessingService.process(text: "keep all details", baseURL: "http://cleanup.test",
                            model: "model", apiKey: "", prompt: "Clean punctuation.", session: session)
                    }
                    XCTFail("An unrelated format failure must propagate")
                } catch {
                    XCTAssertEqual(error.localizedDescription, message)
                }
                XCTAssertEqual(generations.withLock { $0 }, 1, "\(useOllama ? "Ollama" : "Portable"): \(message)")
            }
        }
    }

    func testUnsupportedSchemaClassificationRequiresAnExplicitParameter() {
        for message in ["response_format is not supported", "json_schema is not supported", "structured output is not supported",
                        "format is not supported for cloud models", "unknown parameter: format"] {
            XCTAssertEqual(CleanupRequestAdaptation.unsupportedParameter(in: message), .structuredOutput, message)
        }
        for message in ["unsupported model file format", "audio format is not supported", "unsupported information format",
                        "unsupported model format", "format validation failed", "unknown parameter: model"] {
            XCTAssertNil(CleanupRequestAdaptation.unsupportedParameter(in: message), message)
        }
    }

    func testOllamaReasoningTogglePreservesDefaultsAndSavedOffAcrossMetadataVersions() async throws {
        let suite = "CleanupProviderContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("disabled", forKey: "ollamaReasoningSetting")
        let savedOff = Settings.loadOllamaReasoningEnabled(from: defaults)
        XCTAssertFalse(savedOff)

        let cases: [(model: String, details: String, enabled: Bool,
                     capability: OllamaReasoningCapability, sendsOff: Bool)] = [
            ("test/toggle", #"{"thinking":{"values":[false,true]}}"#, true, .toggle, false),
            ("test/toggle", #"{"thinking":{"values":[false,true]}}"#, savedOff, .toggle, true),
            ("test/levels", #"{"thinking":{"values":["low","medium","high"]}}"#, savedOff, .level, false),
            ("test/required", #"{"thinking":{"values":[true]}}"#, savedOff, .required, false),
            ("test/unknown", #"{}"#, savedOff, .unsupported, false),
            ("qwen3:8b", #"{"capabilities":["completion","thinking"]}"#, savedOff, .toggle, true),
            ("qwen3:8b", #"{"capabilities":["completion","thinking"]}"#, true, .toggle, false),
            ("gpt-oss:20b", #"{"capabilities":["completion","thinking"]}"#, savedOff, .level, false),
            ("local-alias", #"{"capabilities":["completion","thinking"],"details":{"family":"gptoss"}}"#, savedOff, .level, false),
            ("family-alias", #"{"capabilities":["completion","thinking"],"details":{"families":["gpt-oss"]}}"#, savedOff, .level, false),
            ("qwen3:required", #"{"capabilities":["completion","thinking"],"thinking":{"values":[true]}}"#, savedOff, .required, false),
            ("qwen3:empty", #"{"capabilities":["completion","thinking"],"thinking":{"values":[]}}"#, savedOff, .unsupported, false),
            ("qwen3:instruct", #"{"capabilities":["completion"]}"#, savedOff, .unsupported, false),
        ]
        let requests = OSAllocatedUnfairLock(initialState: [[String: Any]]())
        CleanupHTTPStub.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("show") == true {
                let model = try Self.payload(request)["model"] as? String
                let details = try XCTUnwrap(cases.first(where: { $0.model == model })).details
                return (200, Data(details.utf8))
            }
            try requests.withLock { $0.append(try Self.payload(request)) }
            return (200, Data(#"{"done":true,"done_reason":"stop","response":"{\"action\":\"pasteCleanedText\",\"text\":\"Hello.\"}"}"#.utf8))
        } }

        for item in cases {
            let details = try JSONDecoder().decode(OllamaModelDetails.self, from: Data(item.details.utf8))
            XCTAssertEqual(details.reasoningCapability(for: item.model), item.capability, item.model)
            _ = try await OllamaPostProcessingService.process(
                text: "hello", baseURL: "http://cleanup.test", model: item.model,
                reasoningEnabled: item.enabled, prompt: "Correct punctuation.", session: session
            )
        }

        let payloads = requests.withLock { $0 }
        XCTAssertEqual(payloads.count, cases.count)
        for (item, payload) in zip(cases, payloads) {
            if item.sendsOff {
                XCTAssertEqual(payload["think"] as? Bool, false, item.model)
            } else {
                XCTAssertNil(payload["think"], "\(item.model): preserve defaults and required/effort-only reasoning")
            }
        }

        var options = CleanupChatOptions()
        XCTAssertFalse(options.adapt(to: "Unsupported value: temperature only supports the default"))
        XCTAssertFalse(options.adapt(to: "Input exceeds the maximum context length"))
        XCTAssertTrue(options.adapt(to: "json_schema is not supported"))
        XCTAssertFalse(options.structuredOutput)
    }

    func testMissingMetadataDoesNotEstablishNonThinkingGeneration() throws {
        for (json, expected) in [(#"{"capabilities":["completion","tools"]}"#, true),
                                 (#"{"capabilities":["completion","thinking"]}"#, false),
                                 (#"{"capabilities":["embedding"]}"#, false),
                                 (#"{"capabilities":["completion"],"thinking":{"values":[true]}}"#, false),
                                 (#"{}"#, false)] {
            let details = try JSONDecoder().decode(OllamaModelDetails.self, from: Data(json.utf8))
            XCTAssertEqual(details.isKnownNonThinking, expected)
        }
    }
}

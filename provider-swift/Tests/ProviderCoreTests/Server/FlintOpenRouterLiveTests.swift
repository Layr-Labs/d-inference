import Foundation
import MLXLMServer
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Opt-in OpenRouter-style parameter pass for Flint over real weights, the
/// production slot and loopback HTTP, paged attention only. It covers the
/// parameters OpenRouter advertises for Flint: reasoning controls and
/// visibility, stop, JSON response_format (alone and with tools), tools,
/// logprobs and seed. The token is ephemeral and no coordinator is contacted.
@Suite("Flint OpenRouter-style HTTP parameters", .serialized)
struct FlintOpenRouterLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_FLINT_OPENROUTER_LIVE"] == "1"))
    func openRouterParameters() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_FLINT_BACKEND"] == nil || env["DARKBLOOM_FLINT_BACKEND"] == "paged",
            "Flint live qualification requires paged attention")
        let root = try #require(env["DARKBLOOM_FLINT_CACHE"])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }
        let priorCacheSettings = CacheStorage.settings
        let cacheRoot = URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("http-test-cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let volume = try CacheVolume.inspect(directory: cacheRoot.path)
        try CacheStorage.configure(.init(directory: volume.directory, volumeUUID: volume.uuid))
        defer { try? CacheStorage.configure(priorCacheSettings) }
        let id = "RecursiveSI/flint-int4"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: id))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
        try #require(model.modelType == "flint" && model.templateRenderOK == true)
        let port = UInt16(env["DARKBLOOM_FLINT_PORT"] ?? "19094") ?? 19094
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(port: port, host: "127.0.0.1", authToken: token,
            engineV2KVBackend: "paged",
            engineV2KVQuantization: "native", engineV2KVCheckpointQuantization: "native",
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receipt = env["DARKBLOOM_FLINT_RECEIPTS"].map { URL(fileURLWithPath: $0) }
        if let receipt { try Data().write(to: receipt) }

        func post(_ body: [String: Any], path: String = "/v1/chat/completions", name: String) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let started = Date()
            let (data, response) = try await session.data(for: request)
            let status = try #require(response as? HTTPURLResponse).statusCode
            if let receipt {
                let line = try JSONSerialization.data(withJSONObject: ["case": name, "status": status,
                    "seconds": Date().timeIntervalSince(started), "body": String(decoding: data, as: UTF8.self)],
                    options: [.sortedKeys])
                let handle = try FileHandle(forWritingTo: receipt)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: line + Data([10]))
            }
            return (status, data)
        }
        func chat(_ prompt: String, maxTokens: Int = 1024) -> [String: Any] {
            ["model": id, "messages": [["role": "user", "content": prompt]], "temperature": 0,
             "max_tokens": maxTokens, "stream": false]
        }
        func choice(_ data: Data) throws -> [String: Any] {
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let choices = try #require(object["choices"] as? [[String: Any]])
            return try #require(choices.first)
        }
        func message(_ data: Data) throws -> [String: Any] {
            try #require(try choice(data)["message"] as? [String: Any])
        }
        func reasoning(_ message: [String: Any]) -> String {
            (message["reasoning_content"] as? String ?? "") + (message["reasoning"] as? String ?? "")
        }
        let reasoningPrompt = "A train leaves at 3:40 PM and arrives at 6:15 PM. How many minutes is the trip? Answer with the number."

        try await server.start()
        do {
            try #require(await server.waitUntilBound(timeoutSeconds: 10))

            // Reasoning controls are accepted. Flint always chooses whether to
            // reason; effort has no effect and enabled/exclude only control
            // whether reasoning is returned.
            for effort in ["minimal", "low", "medium", "high", "xhigh"] {
                var request = chat(reasoningPrompt)
                request["reasoning"] = ["effort": effort]
                let (code, data) = try await post(request, name: "reasoning-effort-\(effort)")
                try #require(code == 200, "effort \(effort): \(String(decoding: data, as: UTF8.self))")
                #expect((try message(data)["content"] as? String ?? "").contains("155"))
            }
            var topLevelEffort = chat(reasoningPrompt)
            topLevelEffort["reasoning_effort"] = "high"
            #expect(try await post(topLevelEffort, name: "reasoning-effort-top-level").0 == 200)
            var enabled = chat(reasoningPrompt)
            enabled["reasoning"] = ["enabled": true]
            let (enabledCode, enabledData) = try await post(enabled, name: "reasoning-enabled")
            try #require(enabledCode == 200)
            #expect(!reasoning(try message(enabledData)).isEmpty)
            for (name, fields) in [
                ("reasoning-exclude", ["reasoning": ["exclude": true]]),
                ("reasoning-disabled", ["reasoning": ["enabled": false]]),
                ("include-reasoning-false", ["include_reasoning": false]),
            ] as [(String, [String: Any])] {
                var request = chat(reasoningPrompt)
                request.merge(fields) { _, new in new }
                let (code, data) = try await post(request, name: name)
                try #require(code == 200, "\(name): \(String(decoding: data, as: UTF8.self))")
                let value = try message(data)
                #expect(reasoning(value).isEmpty, "\(name) must not return reasoning")
                #expect((value["content"] as? String ?? "").contains("155"))
                #expect(!(value["content"] as? String ?? "").contains("<think>"))
                var streamed = request
                streamed["stream"] = true
                let (streamCode, streamData) = try await post(streamed, name: "\(name)-stream")
                let stream = String(decoding: streamData, as: UTF8.self)
                #expect(streamCode == 200 && stream.contains("[DONE]") && stream.contains("155"))
                #expect(!stream.contains("reasoning_content") && !stream.contains("<think>"))
            }
            var kwargs = chat(reasoningPrompt)
            kwargs["chat_template_kwargs"] = ["enable_thinking": false]
            #expect(try await post(kwargs, name: "chat-template-kwargs-thinking").0 == 200)
            let (respCode, respData) = try await post(["model": id, "input": reasoningPrompt, "temperature": 0,
                "max_output_tokens": 1024, "reasoning": ["effort": "low", "exclude": true]],
                path: "/v1/responses", name: "responses-reasoning-exclude")
            let responsesText = String(decoding: respData, as: UTF8.self)
            #expect(respCode == 200 && responsesText.contains("155"))
            #expect(!responsesText.contains("\"type\":\"reasoning\"") && !responsesText.contains("<think>"))

            // Stop applies only to visible content after reasoning.
            var stop = chat("List the integers from 1 to 12 separated by commas, nothing else.")
            stop["stop"] = ["7"]
            let (stopCode, stopData) = try await post(stop, name: "stop-content")
            try #require(stopCode == 200, "stop: \(String(decoding: stopData, as: UTF8.self))")
            let stopChoice = try choice(stopData)
            let stopContent = (stopChoice["message"] as? [String: Any])?["content"] as? String ?? ""
            #expect(stopChoice["finish_reason"] as? String == "stop")
            #expect(stopContent.contains("6") && !stopContent.contains("7") && !stopContent.contains("12"))
            var stopStream = stop
            stopStream["stream"] = true
            // Reasoning may legitimately mention the stop text; hide it so the
            // stream assertions see only visible content.
            stopStream["reasoning"] = ["exclude": true]
            let (stopStreamCode, stopStreamData) = try await post(stopStream, name: "stop-content-stream")
            let stopStreamText = String(decoding: stopStreamData, as: UTF8.self)
            #expect(stopStreamCode == 200 && stopStreamText.contains("[DONE]"))
            #expect(!stopStreamText.contains("\"content\":\"7") && !stopStreamText.contains("12"))

            // JSON response_format is enforced on the answer after reasoning.
            var jsonObject = chat("Give the capital of France and its country as a JSON object with keys city and country.")
            jsonObject["response_format"] = ["type": "json_object"]
            let (objectCode, objectData) = try await post(jsonObject, name: "response-format-json-object")
            try #require(objectCode == 200, "json_object: \(String(decoding: objectData, as: UTF8.self))")
            let objectContent = try #require(try message(objectData)["content"] as? String)
            #expect((try? JSONSerialization.jsonObject(with: Data(objectContent.utf8)) as? [String: Any]) != nil)
            let schema: [String: Any] = ["type": "object", "additionalProperties": false,
                "required": ["city", "country", "population_millions"],
                "properties": ["city": ["type": "string"], "country": ["type": "string"],
                    "population_millions": ["type": "number"]]]
            var jsonSchema = chat("Describe Paris as JSON with city, country and population in millions.")
            jsonSchema["response_format"] = ["type": "json_schema",
                "json_schema": ["name": "city_fact", "strict": true, "schema": schema]]
            let (schemaCode, schemaData) = try await post(jsonSchema, name: "response-format-json-schema")
            try #require(schemaCode == 200, "json_schema: \(String(decoding: schemaData, as: UTF8.self))")
            let schemaContent = try #require(try message(schemaData)["content"] as? String)
            let schemaObject = try #require(try JSONSerialization.jsonObject(with: Data(schemaContent.utf8)) as? [String: Any])
            #expect(Set(schemaObject.keys) == ["city", "country", "population_millions"])
            #expect(schemaObject["city"] is String && schemaObject["population_millions"] is NSNumber)
            let tool: [String: Any] = ["type": "function", "function": ["name": "get_weather",
                "description": "Get the current weather in a city.", "strict": true,
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]],
                    "required": ["city"], "additionalProperties": false]]]
            var formatWithTools = jsonSchema
            formatWithTools["tools"] = [tool]
            let (formatToolsCode, formatToolsData) = try await post(formatWithTools, name: "response-format-with-tools")
            try #require(formatToolsCode == 200, "format+tools: \(String(decoding: formatToolsData, as: UTF8.self))")
            let formatTools = try message(formatToolsData)
            #expect((formatTools["tool_calls"] as? [[String: Any]] ?? []).isEmpty)
            #expect((try? JSONSerialization.jsonObject(with: Data((formatTools["content"] as? String ?? "").utf8))) != nil)

            // Tools still work alongside the new parameters.
            var named = chat("Use get_weather to check the weather in Paris. Do not guess.")
            named["tools"] = [tool]
            named["tool_choice"] = ["type": "function", "function": ["name": "get_weather"]]
            named["reasoning"] = ["effort": "low", "exclude": true]
            let (namedCode, namedData) = try await post(named, name: "tools-named-with-reasoning-controls")
            try #require(namedCode == 200)
            let namedMessage = try message(namedData)
            #expect((namedMessage["tool_calls"] as? [[String: Any]] ?? []).count == 1)
            #expect(reasoning(namedMessage).isEmpty)

            // logprobs / top_logprobs.
            var logprobs = chat("What is 2 + 2? Answer with the number.", maxTokens: 512)
            logprobs["logprobs"] = true
            logprobs["top_logprobs"] = 3
            let (logprobsCode, logprobsData) = try await post(logprobs, name: "logprobs")
            try #require(logprobsCode == 200, "logprobs: \(String(decoding: logprobsData, as: UTF8.self))")
            let entries = ((try choice(logprobsData)["logprobs"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            #expect(!entries.isEmpty)
            #expect(entries.allSatisfy { ($0["logprob"] as? Double).map { $0 <= 0 } == true })
            #expect(entries.contains { ($0["top_logprobs"] as? [[String: Any]])?.count == 3 })

            // seed: same seed and sampling settings reproduce the output.
            var seeded = chat("Name one primary color.", maxTokens: 512)
            seeded["temperature"] = 1.0
            seeded["seed"] = 42
            let (seedA, seedDataA) = try await post(seeded, name: "seed-a")
            let (seedB, seedDataB) = try await post(seeded, name: "seed-b")
            try #require(seedA == 200 && seedB == 200)
            #expect(try message(seedDataA)["content"] as? String == (try message(seedDataB)["content"] as? String))
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(server.responseTracker.activeCount == 0)
        #expect(await server.debugActiveRequestCount(modelId: id) == nil)
    }
}

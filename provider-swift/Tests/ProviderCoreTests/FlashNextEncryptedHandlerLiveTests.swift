import Foundation
import Testing
@testable import ProviderCore

/// Opt-in real-model handler coverage. Identity and authenticated tenant are
/// injected. Loopback WebSocket transport is real; attestation and coordinator
/// account authentication are not certified. All cases share one model load.
@Suite("Flash-Next real encrypted handler", .serialized)
struct FlashNextEncryptedHandlerLiveTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_FLASH_NEXT_HANDLER_LIVE"] == "1",
        "Requires the explicit owned Flash-Next artifact and exclusive model lane"))
    func realModelEncryptsResponseAndRetires() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_PREFIX_CACHE"] == "0")
        let path = try #require(env["DARKBLOOM_QWEN4_REAL_MODEL"])
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let modelID = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"
        let resolved = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        // The serving snapshot contains individual symlinks, not necessarily
        // a directory symlink. Require every indexed shard and serving metadata
        // file to resolve to the same filesystem object as the owned artifact.
        let indexData = try Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))
        let index = try #require(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let weightMap = try #require(index["weight_map"] as? [String: String])
        let metadata = ["config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json"]
        for name in Set(weightMap.values).union(metadata) {
            try #require(!name.contains("/") && name != "..", "unexpected artifact entry")
            let actual = try FileManager.default.attributesOfItem(
                atPath: resolved.appendingPathComponent(name).resolvingSymlinksInPath().path)
            let expected = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).resolvingSymlinksInPath().path)
            try #require(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
            try #require(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        }
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let hardware = try HardwareDetector.detect()
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:1/unused", hardware: hardware,
            models: [model], config: ProviderConfig(
                provider: ProviderSettings(name: "flash-next-handler-fixture"),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1)))
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flash-next-handler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
        let recorder = FlashNextHandlerRecorder()
        let mock = MockCoordinator()
        var client: CoordinatorClient?
        var pump: Task<Void, Never>?
        var sentRequestIDs: [String] = []
        let runID = UUID().uuidString
        do {
            try await loop.ensureModelLoaded(modelId: modelID, allowEviction: false)
            let consumer = NodeKeyPair.generate()
            let providerKey = await loop.keyPair.publicKeyBytes
            let baseURL = try await mock.start()
            let connected = CoordinatorClient(
                config: CoordinatorClientConfig(
                    url: baseURL.mockProviderWebSocketURL(), hardware: hardware,
                    models: [model], backendName: "mlx-swift",
                    publicKey: providerKey.base64EncodedString()),
                stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
            client = connected
            let (events, sendFn) = await connected.start()
            let send = SendHandle { message in
                recorder.record(message)
                sendFn(message)
            }
            pump = Task {
                for await event in events {
                    if case .inferenceRequest(let id, let ciphertext, let sender, let nonce,
                        let scope, let protocolVersion, let boundary, let toolProtocol,
                        let deadline, let received, let profile) = event {
                        await loop.handleInferenceRequest(
                            requestId: id, ciphertext: ciphertext, senderPublicKey: sender,
                            cacheReceiptNonce: nonce, authenticatedCacheScope: scope,
                            prefixCacheProtocol: protocolVersion, cacheReceiptBoundaryMode: boundary,
                            toolSchemaMetadataProtocol: toolProtocol, firstContentDeadline: deadline,
                            receivedAt: received, profile: profile, send: send)
                    }
                }
            }
            let registration = try await mock.awaitFirstRegister(timeout: .seconds(10))
            try #require(registration != nil)
            let toolPrompt = "Use the add tool once with a=7 and b=5. After its result arrives, reply with exactly the resulting integer and no other text."
            var cases = FlashNextHandlerCase.toolCases(prompt: toolPrompt)
            cases.insert(.init(name: "plain", fields: [
                "messages": [["role": "user", "content": "Reply with exactly: handler works"]]
            ], expectedText: "handler works"), at: 0)
            var callIDs = Set<String>()
            var historyCall: FlashNextHandlerCall?
            for fixture in cases {
                let requestID = "flash-next-\(runID)-\(fixture.name)"
                sentRequestIDs.append(requestID)
                let result = try await run(fixture, requestID: requestID, modelID: modelID,
                    consumer: consumer, providerKey: providerKey, mock: mock, recorder: recorder)
                if fixture.expectedText == nil {
                    let call = try #require(result.calls.first)
                    #expect(callIDs.insert(call.id).inserted, "tool call IDs must be unique across requests")
                    if fixture.name == "auto" { historyCall = call }
                }
            }
            let call = try #require(historyCall)
            let history = FlashNextHandlerCase(name: "tool-history", fields: [
                "messages": [
                    ["role": "user", "content": toolPrompt],
                    ["role": "assistant", "content": "", "tool_calls": [call.history]],
                    ["role": "tool", "tool_call_id": call.id, "content": "12"],
                ],
                "tools": [FlashNextHandlerCase.tool(named: "add")], "tool_choice": "auto",
            ], expectedText: "12")
            let historyID = "flash-next-\(runID)-tool-history"
            sentRequestIDs.append(historyID)
            _ = try await run(history, requestID: historyID, modelID: modelID,
                consumer: consumer, providerKey: providerKey, mock: mock, recorder: recorder)
            let finalWire = try #require(await mock.waitForSnapshot(timeout: .seconds(10)) {
                $0.inferenceComplete.count == 6 || !$0.inferenceErrors.isEmpty
            })
            #expect(finalWire.inferenceErrors.isEmpty)
            #expect(finalWire.inferenceComplete.count == sentRequestIDs.count)
            #expect(Set(finalWire.inferenceComplete.map(\.requestId)) == Set(sentRequestIDs))
            for requestID in sentRequestIDs {
                #expect(recorder.terminalCount(for: requestID) == 1)
            }
            _ = await loop.unloadModel(modelID)
            await connected.shutdown()
            pump?.cancel()
            await pump?.value
            await mock.shutdown()
        } catch {
            for requestID in sentRequestIDs { await loop.handleCancellation(requestId: requestID) }
            _ = await loop.unloadModel(modelID)
            await client?.shutdown()
            pump?.cancel()
            await pump?.value
            await mock.shutdown()
            throw error
        }
    }

    private func run(_ fixture: FlashNextHandlerCase, requestID: String, modelID: String,
        consumer: NodeKeyPair, providerKey: Data, mock: MockCoordinator,
        recorder: FlashNextHandlerRecorder) async throws -> FlashNextHandlerOutput
    {
        var request: [String: Any] = [
            "model": modelID, "temperature": 0, "max_tokens": 128,
            "reasoning": ["enabled": false], "enable_thinking": false,
            "reasoning_effort": "none", "stream": true,
            "stream_options": ["include_usage": true], "parallel_tool_calls": false,
        ]
        request.merge(fixture.fields) { _, value in value }
        try await mock.pushInferenceRequest(requestId: requestID,
            providerPublicKeyBase64: providerKey.base64EncodedString(),
            chatRequestJSON: JSONSerialization.data(withJSONObject: request),
            firstContentBudgetMs: 120_000, cacheScope: "synthetic-tenant", consumerKeyPair: consumer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while recorder.terminalCount(for: requestID) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(recorder.terminalCount(for: requestID) == 1, "\(fixture.name): handler did not terminate exactly once")
        let wire = try #require(await mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == requestID }
                || $0.inferenceErrors.contains { $0.requestId == requestID }
        })
        let failures = wire.inferenceErrors.filter { $0.requestId == requestID }
        try #require(failures.isEmpty, "\(fixture.name): encrypted handler reported a failure")
        let terminals = wire.inferenceComplete.filter { $0.requestId == requestID }
        try #require(terminals.count == 1)
        let terminal = try #require(terminals.first)
        let chunks = wire.inferenceChunks.filter { $0.requestId == requestID }
        try #require(!chunks.isEmpty)
        let sent = recorder.chunks(for: requestID)
        #expect(sent.count == chunks.count)
        #expect(sent.allSatisfy { $0.data.isEmpty && $0.encryptedData != nil })
        #expect(chunks.map(\.encryptedData) == sent.map(\.encryptedData))
        var output = FlashNextHandlerOutput()
        // Inspect the bytes actually received by the mock over WebSocket, not
        // merely the sender's copy. Only the supplied consumer key decrypts it.
        for chunk in chunks {
            #expect(chunk.data.isEmpty)
            let data = try consumer.decryptPayload(#require(chunk.encryptedData))
            try output.consume(data)
        }
        #expect(output.doneCount == 1, "\(fixture.name): exactly one SSE terminal")
        #expect(output.finishReasons.count == 1)
        #expect(output.reasoning.isEmpty, "\(fixture.name): reasoning must stay disabled")
        for marker in ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=", "<parameter="] {
            #expect(!output.content.contains(marker), "\(fixture.name): frame leaked into content")
        }
        #expect(terminal.usage.promptTokens > 0 && terminal.usage.completionTokens > 0)
        #expect(output.promptTokens == Int(terminal.usage.promptTokens))
        #expect(output.completionTokens == Int(terminal.usage.completionTokens))
        if let text = fixture.expectedText {
            #expect(output.calls.isEmpty)
            #expect(output.content.trimmingCharacters(in: .whitespacesAndNewlines) == text)
            #expect(output.finishReasons == ["stop"])
        } else {
            #expect(output.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(output.finishReasons == ["tool_calls"])
            try #require(output.calls.count == 1)
            let call = try #require(output.calls.first)
            #expect(!call.id.isEmpty && call.name == "add")
            let arguments = try JSONDecoder().decode([String: Int].self, from: Data(call.arguments.utf8))
            #expect(arguments == ["a": 7, "b": 5])
        }
        print("Flash-Next encrypted WebSocket case \(fixture.name) completed: prompt=\(terminal.usage.promptTokens), output=\(terminal.usage.completionTokens)")
        return output
    }
}

private final class FlashNextHandlerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
    func terminalCount(for requestID: String) -> Int { snapshot.filter {
        switch $0 {
        case .inferenceComplete(let id, _, _, _, _, _), .inferenceError(let id, _, _): id == requestID
        default: false
        }
    }.count }
    func chunks(for requestID: String) -> [ProviderMessage.InferenceResponseChunk] {
        snapshot.compactMap {
            guard case .inferenceChunk(let id, let data, let encrypted) = $0, id == requestID else { return nil }
            return .init(requestId: id, data: data, encryptedData: encrypted)
        }
    }
}

private struct FlashNextHandlerCase {
    let name: String
    let fields: [String: Any]
    var expectedText: String? = nil

    static func tool(named name: String) -> [String: Any] {
        ["type": "function", "function": [
            "name": name,
            "description": name == "add" ? "Add the two integers." : "Subtract b from a.",
            "parameters": ["type": "object", "properties": [
                "a": ["type": "integer"], "b": ["type": "integer"],
            ], "required": ["a", "b"], "additionalProperties": false],
        ]]
    }

    static func toolCases(prompt: String) -> [Self] {
        var cases: [Self] = ["auto", "required", "named"].map { name in
            .init(name: name, fields: [
                "messages": [["role": "user", "content": prompt]],
                "tools": name == "named" ? [tool(named: "add"), tool(named: "subtract")] : [tool(named: "add")],
                "tool_choice": name == "named"
                    ? ["type": "function", "function": ["name": "add"]] as Any : name,
            ])
        }
        cases.append(.init(name: "none", fields: [
            "messages": [["role": "user", "content": "Do not use tools. Reply with exactly the integer result of 7+5."]],
            "tools": [tool(named: "add")], "tool_choice": "none",
        ], expectedText: "12"))
        return cases
    }
}

private struct FlashNextHandlerCall {
    var id = ""
    var name = ""
    var arguments = ""
    var history: [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }
}

private struct FlashNextHandlerOutput {
    var content = ""
    var reasoning = ""
    var doneCount = 0
    var finishReasons: [String] = []
    var promptTokens: Int?
    var completionTokens: Int?
    private var callsByIndex: [Int: FlashNextHandlerCall] = [:]
    var calls: [FlashNextHandlerCall] { callsByIndex.keys.sorted().compactMap { callsByIndex[$0] } }

    mutating func consume(_ data: Data) throws {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            let text = String(line.dropFirst(6))
            if text == "[DONE]" { doneCount += 1; continue }
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(object["error"] == nil)
            if let usage = object["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int
                completionTokens = usage["completion_tokens"] as? Int
            }
            for choice in (object["choices"] as? [[String: Any]]) ?? [] {
                if let reason = choice["finish_reason"] as? String { finishReasons.append(reason) }
                let delta = (choice["delta"] as? [String: Any]) ?? [:]
                content += (delta["content"] as? String) ?? ""
                reasoning += (delta["reasoning_content"] as? String) ?? ""
                reasoning += (delta["reasoning"] as? String) ?? ""
                for fragment in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                    let index = try #require(fragment["index"] as? Int)
                    var call = callsByIndex[index] ?? .init()
                    if let id = fragment["id"] as? String {
                        #expect(call.id.isEmpty || call.id == id)
                        call.id = id
                    }
                    if let type = fragment["type"] as? String { #expect(type == "function") }
                    if let function = fragment["function"] as? [String: Any] {
                        call.name += (function["name"] as? String) ?? ""
                        call.arguments += (function["arguments"] as? String) ?? ""
                    }
                    callsByIndex[index] = call
                }
            }
        }
    }
}

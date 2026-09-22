import CoreImage
import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionEncryptedBundleAnchor: NSObject {}

/// Real provider receive/decrypt/native-inference/encrypt/WebSocket delivery.
/// The coordinator and authenticated tenant are test fixtures; this does not
/// certify hosted accounts, App Attest or production authorization.
@Suite("DiffusionGemma encrypted provider WebSocket", .serialized)
struct DiffusionGemmaEncryptedHandlerLiveTests {
    private static let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_ENCRYPTED_LIVE"] == "1"))
    func nativeTextToolsMediaAndHistoryCrossTheEncryptedWire() async throws {
        let cacheDisabled = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE"] == "0"
        try #require(cacheDisabled, "Keep this transport gate separate from cache qualification")
        let selectedPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]
        let directory = URL(fileURLWithPath: try #require(selectedPath)).resolvingSymlinksInPath()
        let resolved = try #require(ModelScanner.resolveLocalPath(modelID: Self.modelID))
        let index = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let map = try #require(index["weight_map"] as? [String: String])
        for name in Set(map.values).union(["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"]) {
            try #require(!name.contains("/") && name != "..")
            try #require(resolved.appendingPathComponent(name).resolvingSymlinksInPath()
                == directory.appendingPathComponent(name).resolvingSymlinksInPath())
        }
        try #require(hashFile(atPath: directory.appendingPathComponent("local-verified-manifest.json").path)
            == "33eb488387819e31d1a848e7d0f20465ae6ad0ae1ed31dac7aa4cb5e0461d53d")
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionEncryptedBundleAnchor.self).bundleURL
        let originalHash = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.modelID))
        let hardware = try HardwareDetector.detect()
        let config = ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:1/unused", hardware: hardware,
            models: [model], config: ProviderConfig(
                provider: ProviderSettings(name: "diffusion-handler-fixture"),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1,
                    engineV2KVBackend: "paged", mtpMode: .auto)))
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffusion-handler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
        let recorder = DiffusionEncryptedRecorder()
        let mock = MockCoordinator()
        var client: CoordinatorClient?
        var pump: Task<Void, Never>?
        var ids = [String]()
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false)
            let bridge = try #require(await loop.slotBridgeForTesting(modelId: Self.modelID))
            try #require(await bridge.isNativeDiffusionForEncryptedTest())
            try #require(await bridge.kvBackendKind == .paged)
            let consumer = NodeKeyPair.generate()
            let wrongConsumer = NodeKeyPair.generate()
            let publicKey = await loop.keyPair.publicKeyBytes
            let url = try await mock.start()
            let connected = CoordinatorClient(config: CoordinatorClientConfig(
                url: url.mockProviderWebSocketURL(), hardware: hardware, models: [model],
                backendName: "mlx-swift", publicKey: publicKey.base64EncodedString()),
                stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
            client = connected
            let (events, sendFn) = await connected.start()
            let send = SendHandle { message in recorder.record(message); sendFn(message) }
            pump = Task {
                for await event in events {
                    if case .inferenceRequest(let id, let ciphertext, let sender, let nonce,
                        let scope, let version, let boundary, let toolProtocol, let deadline,
                        let received, let profile) = event {
                        await loop.handleInferenceRequest(requestId: id, ciphertext: ciphertext,
                            senderPublicKey: sender, cacheReceiptNonce: nonce,
                            authenticatedCacheScope: scope, prefixCacheProtocol: version,
                            cacheReceiptBoundaryMode: boundary, toolSchemaMetadataProtocol: toolProtocol,
                            firstContentDeadline: deadline, receivedAt: received, profile: profile, send: send)
                    }
                }
            }
            let registration = try await mock.awaitFirstRegister(timeout: .seconds(10))
            let registered = registration != nil
            try #require(registered)
            let tools: [[String: Any]] = [["type": "function", "function": ["name": "get_weather",
                "description": "Get the current weather for a city.", "parameters": ["type": "object",
                    "properties": ["city": ["type": "string"]], "required": ["city"], "additionalProperties": false]]]]
            let weather = "Use get_weather to check the current weather in Paris. Do not guess the weather."
            let image = CIImage(color: .blue).cropped(to: .init(x: 0, y: 0, width: 64, height: 64))
            let png = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let fixtures: [(String, Bool, UInt64, [String: Any])] = [
                ("plain", false, 341, ["messages": [["role": "user", "content": "What is 17 times 19? Reply with the number only."]]]),
                ("tool-off", false, 7419, ["messages": [["role": "user", "content": weather]], "tools": tools, "tool_choice": "required"]),
                ("tool-on", true, 7419, ["messages": [["role": "user", "content": weather]], "tools": tools, "tool_choice": "required"]),
                ("image", false, 8132, ["messages": [["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
                    ["type": "text", "text": "Name the single dominant color of this image. Reply using only the color name."]]]]]),
            ]
            var calls = [DiffusionEncryptedCall]()
            for (name, thinking, seed, fields) in fixtures {
                let id = "diffusion-wire-\(UUID().uuidString)"
                ids.append(id)
                let output = try await run(name, id: id, thinking: thinking, seed: seed, fields: fields,
                    consumer: consumer, wrongConsumer: wrongConsumer, providerKey: publicKey, mock: mock, recorder: recorder)
                if name.hasPrefix("tool-") {
                    try #require(output.calls.count == 1)
                    let call = try #require(output.calls.first)
                    #expect(!call.id.isEmpty && call.name == "get_weather")
                    #expect(try JSONDecoder().decode([String: String].self, from: Data(call.arguments.utf8)) == ["city": "Paris"])
                    #expect(output.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    #expect(output.finishes == ["tool_calls"])
                    calls.append(call)
                } else {
                    #expect(output.calls.isEmpty && output.finishes == ["stop"])
                    #expect(output.content.lowercased().contains(name == "plain" ? "323" : "blue"))
                }
            }
            #expect(Set(calls.map(\.id)).count == calls.count)
            let call = try #require(calls.first)
            let historyID = "diffusion-wire-\(UUID().uuidString)"
            ids.append(historyID)
            let history: [String: Any] = ["messages": [
                ["role": "user", "content": weather],
                ["role": "assistant", "content": "", "tool_calls": [call.history]],
                ["role": "tool", "tool_call_id": call.id,
                 "content": "{\"city\":\"Paris\",\"temperature_c\":20,\"condition\":\"sunny\"}"],
                ["role": "user", "content": "In one sentence, report the temperature and condition from the tool result."]],
                "tools": tools, "tool_choice": "auto"]
            let replay = try await run("history", id: historyID, thinking: false, seed: 341, fields: history,
                consumer: consumer, wrongConsumer: wrongConsumer, providerKey: publicKey, mock: mock, recorder: recorder)
            #expect(replay.calls.isEmpty && replay.content.contains("20") && replay.content.lowercased().contains("sunny"))
            let mtp = await bridge.mtpStatusSnapshot()
            #expect(!mtp.active && mtp.proposedTokens == 0 && mtp.acceptedDraftTokens == 0,
                "AUTO must not invent an AR assistant for native diffusion")
            let snapshot = await mock.snapshot()
            #expect(snapshot.inferenceErrors.isEmpty && snapshot.inferenceComplete.count == ids.count)
            for id in ids { #expect(recorder.terminalCount(id) == 1) }
            #expect(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID) == originalHash)
            _ = await loop.unloadModel(Self.modelID)
            await connected.shutdown(); pump?.cancel(); await pump?.value; await mock.shutdown()
        } catch {
            for id in ids { await loop.handleCancellation(requestId: id) }
            _ = await loop.unloadModel(Self.modelID)
            await client?.shutdown(); pump?.cancel(); await pump?.value; await mock.shutdown()
            throw error
        }
    }

    private func run(_ name: String, id: String, thinking: Bool, seed: UInt64, fields: [String: Any],
        consumer: NodeKeyPair, wrongConsumer: NodeKeyPair, providerKey: Data,
        mock: MockCoordinator, recorder: DiffusionEncryptedRecorder) async throws -> DiffusionEncryptedOutput {
        var request: [String: Any] = ["model": Self.modelID, "temperature": 1, "seed": seed,
            "max_tokens": 512, "reasoning": ["enabled": thinking], "stream": true,
            "stream_options": ["include_usage": true], "parallel_tool_calls": false]
        request.merge(fields) { _, value in value }
        try await mock.pushInferenceRequest(requestId: id, providerPublicKeyBase64: providerKey.base64EncodedString(),
            chatRequestJSON: JSONSerialization.data(withJSONObject: request), firstContentBudgetMs: 120_000,
            cacheScope: "synthetic-diffusion-tenant", consumerKeyPair: consumer)
        let snapshot = try #require(await mock.waitForSnapshot(timeout: .seconds(120)) {
            $0.inferenceComplete.contains { $0.requestId == id } || $0.inferenceErrors.contains { $0.requestId == id }
        })
        try #require(snapshot.inferenceErrors.filter { $0.requestId == id }.isEmpty, "Native encrypted \(name) failed")
        let terminal = try #require(snapshot.inferenceComplete.first { $0.requestId == id })
        #expect(recorder.terminalCount(id) == 1)
        let chunks = snapshot.inferenceChunks.filter { $0.requestId == id }
        let sent = recorder.chunks(id)
        try #require(!chunks.isEmpty)
        #expect(sent.count == chunks.count && sent.map(\.encryptedData) == chunks.map(\.encryptedData))
        var output = DiffusionEncryptedOutput()
        for chunk in chunks {
            #expect(chunk.data.isEmpty)
            let encrypted = try #require(chunk.encryptedData)
            try output.consume(consumer.decryptPayload(encrypted))
            var wrongKeyRejected = false
            do { _ = try wrongConsumer.decryptPayload(encrypted) } catch { wrongKeyRejected = true }
            #expect(wrongKeyRejected)
        }
        #expect(output.done == 1 && output.finishes.count == 1 && output.usageCount == 1)
        #expect(output.prompt == Int(terminal.usage.promptTokens) && output.completion == Int(terminal.usage.completionTokens))
        #expect(terminal.usage.promptTokens > 0 && terminal.usage.completionTokens > 0)
        if !thinking { #expect(output.reasoning.isEmpty) }
        for marker in ["<|channel>", "<channel|>", "<|tool_call>", "<tool_call|>", "<|turn>", "<turn|>"] {
            #expect(!output.content.contains(marker))
        }
        print("DIFFUSION_ENCRYPTED case=\(name) wireCiphertext=true wrongKeyRejected=true terminal=1 prompt=\(terminal.usage.promptTokens) output=\(terminal.usage.completionTokens)")
        return output
    }
}

private extension EngineV2Bridge {
    func isNativeDiffusionForEncryptedTest() -> Bool { ownedEngine is CBv2NativeBlockEngine }
}

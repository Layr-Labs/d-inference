// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

/// The managed Super slot through `ProviderLoop`: exact-identity load into a
/// shared slot with the real LOAD claim and re-slice grant, the encrypted
/// coordinator request path and the unified local endpoint on the same owner,
/// cancellation, admission refusal and retirement. Tiny synthetic weights run
/// through the real `NemotronSuperLocalLoad` transaction; the pinned
/// checkpoint itself is not loaded here.
@Suite(.serialized)
struct NemotronSuperManagedSlotTests {
    private static let modelID = NemotronSuperServingPolicy.modelID

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []
        func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
        var snapshot: [OutboundMessage] { lock.withLock { messages } }
        func terminal(_ id: String) -> OutboundMessage? {
            snapshot.first {
                switch $0 {
                case .inferenceComplete(let request, _, _, _, _, _), .inferenceError(let request, _, _):
                    request == id
                default: false
                }
            }
        }
        func chunks(_ id: String) -> [EncryptedPayload] {
            snapshot.compactMap {
                if case .inferenceChunk(let request, _, let payload) = $0, request == id { return payload }
                return nil
            }
        }
    }

    private struct Fixture {
        let loop: ProviderLoop
        let budget: GlobalKVCacheBudget
        let script: SuperOutputScript
        let directory: URL
    }

    /// `totalGiB` bounds the process budget the LOAD claim and requests use.
    private static func fixture(mode: MTPMode, totalGiB: UInt64 = 64) async throws -> Fixture {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: totalGiB << 30, active: 0, cache: 0, systemAvailable: totalGiB << 30)
        }
        let hardware = HardwareInfo(machineModel: "Mac15,14", chipName: "Apple M3 Ultra",
            chipFamily: .m3, chipTier: .ultra, memoryGb: totalGiB, memoryAvailableGb: totalGiB,
            cpuCores: .init(total: 28, performance: 20, efficiency: 8), gpuCores: 60, memoryBandwidthGbs: 819)
        let model = ModelInfo(id: modelID, modelType: "nemotron_h_omni", sizeBytes: 1 << 20,
                              estimatedMemoryGb: 0.01)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [model], config: .init(provider: .init(name: "super-managed"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: mode),
                coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        let script = SuperOutputScript()
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        await loop.setNemotronSuperSlotLoaderForTesting(
            loader(tokenizer: TokenizerHandle(SuperScriptedTokenizer(script: script)), template: template),
            environment: [:])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("super-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(#"{"model_type":"nemotron_h_omni"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        return Fixture(loop: loop, budget: budget, script: script, directory: directory)
    }

    /// The latent-MoE fixture and its embedded head, staged through the real
    /// transaction under the provider's grant, admission and environment.
    private static func loader(tokenizer: TokenizerHandle, template: Data) -> NemotronSuperSlotLoader {
        NemotronSuperSlotLoader(kvBytesPerToken: { _ in 64 }) { request in
            let staging = try SuperMTPInstalledFixture().staging()
            let tensorBytes = staging.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
            let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 16)
            let transaction = NemotronSuperLocalLoad(budget: request.budget)
            let bridge = try await transaction.load(staging: { staging }, tokenizer: tokenizer,
                eosTokenIDs: [], sizing: sizing, kvBytesCapacity: request.kvBytesCapacity,
                admissionKVBytes: request.admissionKVBytes, backendAllowanceBytes: 1 << 20,
                modelID: request.modelID, environment: request.environment)
            return try await NemotronSuperSlotOwner(transaction: transaction, bridge: bridge,
                tokenizer: tokenizer, sizing: sizing, templateBytes: template)
        }
    }

    private static func body(_ pieces: [String], script: SuperOutputScript,
                             _ extra: [String: Any] = [:]) throws -> Data {
        script.set(pieces)
        var value: [String: Any] = ["model": modelID, "stream": true, "temperature": 0,
            "max_tokens": pieces.count, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hi"]]]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// One encrypted coordinator request: the decrypted SSE and its terminal.
    private static func send(_ body: Data, to loop: ProviderLoop, recorder: Recorder,
        consumer: NodeKeyPair, scope: String? = "tenant-a",
        whileRunning: (@Sendable (String) async -> Void)? = nil
    ) async throws -> (sse: String, terminal: OutboundMessage) {
        let id = "super-coordinator-\(UUID().uuidString)"
        let ciphertext = try consumer.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes,
                                              plaintext: body)
        await loop.handleInferenceRequest(requestId: id, ciphertext: ciphertext,
            senderPublicKey: consumer.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: scope, send: SendHandle(recorder.record))
        if let whileRunning { await whileRunning(id) }
        let deadline = ContinuousClock.now + .seconds(60)
        while recorder.terminal(id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let terminal = try #require(recorder.terminal(id))
        let frames = try recorder.chunks(id).map { String(decoding: try consumer.decryptPayload($0), as: UTF8.self) }
        return (frames.joined(), terminal)
    }

    private static func usage(_ terminal: OutboundMessage) -> UsageInfo? {
        if case .inferenceComplete(_, let usage, _, _, _, _) = terminal { return usage }
        return nil
    }

    private static func failure(_ terminal: OutboundMessage) -> InferenceFailure? {
        if case .inferenceError(_, let failure, _) = terminal { return failure }
        return nil
    }

    @Test(.timeLimit(.minutes(3)))
    func managedSlotServesCoordinatorAndLocalRequestsThroughTheOwner() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.speculates && owner.modelID == Self.modelID)
        #expect(await owner.bridge.maxConcurrentRequests == 8)
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelID) === owner.bridge)
        let mtp = await owner.bridge.mtpStatusSnapshot()
        #expect(mtp.configured && mtp.active)
        // Reasoning, plain content and usage through the encrypted path.
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let pieces = ["Hello", " there", "."]
        let text = try await Self.send(Self.body(pieces, script: script), to: loop, recorder: recorder,
                                       consumer: consumer)
        let streamed = SuperSSE(text.sse)
        let coordinatorPrompt = script.prompt
        #expect(streamed.content == "Hello there." && streamed.reasoning.isEmpty)
        #expect(script.prompt.hasPrefix("<|im_start|>system\nBe brief.<|im_end|>\n"))
        #expect(script.prompt.hasSuffix("<|im_start|>assistant\n<think></think>"))
        let usage = try #require(Self.usage(text.terminal))
        #expect(usage.promptTokens == 3 && usage.completionTokens == 3)
        #expect(usage.cacheOutcome == nil && usage.cachedTokens == nil)
        // Tools are held until validated, then returned as tool calls.
        let weather: [String: Any] = ["type": "function", "function": ["name": "get_weather",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]]
        let call = ["<tool_call>", "\n<function=get_weather>", "\n<parameter=city>", "\nParis",
                    "\n</parameter>", "\n</function>", "\n</tool_call>"]
        let tool = try await Self.send(Self.body(call, script: script, ["tools": [weather]]), to: loop,
                                       recorder: recorder, consumer: consumer)
        #expect(SuperSSE(tool.sse).toolCalls.map(\.name) == ["get_weather"])
        #expect(SuperSSE(tool.sse).toolCalls.map(\.arguments) == [#"{"city":"Paris"}"#])
        #expect(!tool.sse.contains("<tool_call>"))
        // The slot advertises no media, and unhonored controls are refused.
        let image = ["role": "user", "content": [["type": "image_url", "image_url": ["url":
            "data:image/png;base64,iVBORw0KGgo="]], ["type": "text", "text": "Describe."]]] as [String: Any]
        for extra in [["messages": [image]], ["logit_bias": ["5": 2]], ["logprobs": true]] as [[String: Any]] {
            let refused = try await Self.send(Self.body(["x"], script: script, extra), to: loop,
                                              recorder: recorder, consumer: consumer)
            #expect(Self.failure(refused.terminal)?.statusCode == 400, "\(extra.keys.sorted())")
        }

        // The unified local endpoint serves the same owner identically.
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "super-managed"), defaultMaxTokens: 16,
            acquire: { id in try await loop.acquireModelForLocal(id) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [Self.modelID] }, mtpSlots: { [] },
            managedSuperEngine: { body, request in
                guard request.model == Self.modelID else { return nil }
                return NemotronSuperLocalEndpointEngine(body: body, hasMedia: false, cacheScope: "local",
                    acquire: { try await loop.acquireNemotronSuperForLocal(Self.modelID) })
            })
        try await app.test(.live) { client in
            let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer super-managed"]
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                body: ByteBuffer(bytes: try Self.body(pieces, script: script))) { response in
                #expect(response.status == .ok)
                let local = SuperSSE(String(buffer: response.body))
                #expect(local.content == streamed.content && local.reasoning == streamed.reasoning)
                #expect(local.finishReason == streamed.finishReason)
            }
            // The generic local engine never serves Super.
            try await client.execute(uri: "/v1/completions", method: .post, headers: headers,
                body: ByteBuffer(string: #"{"model":"\#(Self.modelID)","prompt":"Hi","max_tokens":1}"#)) { response in
                #expect(response.status != .ok)
            }
        }
        #expect(script.prompt == coordinatorPrompt, "local and coordinator render the same reference prompt")

        // Unload retires the owner: no charge, lane or prefix bank survives.
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil)
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelID) == nil)
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
    }

    /// A coordinator cancel mid-stream settles once and the owner still retires.
    @Test(.timeLimit(.minutes(3)))
    func coordinatorCancellationSettlesAndTheOwnerRetires() async throws {
        let fixture = try await Self.fixture(mode: .off)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(!owner.speculates)
        // The plain owner holds its lane and exact text prefix bank from load.
        let held = await fixture.budget.reservationBytesSnapshot().keys
        #expect(held.contains(where: NemotronSuperLocalPrefill.isLaneReservationID))
        #expect(held.contains(where: NemotronSuperLocalPrefixCache.isBankReservationID))
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let long = Array(repeating: "a", count: 900)
        let cancelled = try await Self.send(Self.body(long, script: fixture.script), to: loop,
            recorder: recorder, consumer: consumer) { id in
            let deadline = ContinuousClock.now + .seconds(30)
            while recorder.chunks(id).count < 3, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            await loop.handleCancellation(requestId: id)
        }
        // Output was delivered, so the cancel settles as a partial completion
        // billed for what was produced, never the length limit.
        let settled = try #require(Self.usage(cancelled.terminal), "\(cancelled.terminal)")
        #expect(settled.completionTokens > 0 && settled.completionTokens < 900)
        #expect(settled.promptTokens == 3)
        let delivered = SuperSSE(cancelled.sse).content
        #expect(!delivered.isEmpty && delivered.allSatisfy { $0 == "a" } && delivered.count < 900)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.reservationBytesSnapshot().isEmpty)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// The LOAD claim refuses before allocation; nothing is installed or held.
    @Test(.timeLimit(.minutes(1)))
    func loadAdmissionRefusalInstallsNothing() async throws {
        // The ordinary load gate passes; the managed claim's 26 GiB KV headroom does not.
        let fixture = try await Self.fixture(mode: .auto, totalGiB: 16)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var refusal: Error?
        do {
            try await fixture.loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                                     revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let error = try #require(refusal)
        #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
        #expect("\(error)".contains("insufficient memory at LOAD admission"))
        #expect(await fixture.loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        #expect(await fixture.loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
    }
}

// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// The managed Super slot through `ProviderLoop`: exact-identity load into a
/// shared slot with the real LOAD claim and re-slice grant, the encrypted
/// coordinator request path and the unified local endpoint on the same owner,
/// cancellation, admission refusal and retirement. Image requests are in
/// `NemotronSuperManagedSlotTests+Images.swift`. Tiny synthetic weights run
/// through the real `NemotronSuperLocalLoad` transaction; the pinned
/// checkpoint itself is not loaded here.
@Suite(.serialized)
struct NemotronSuperManagedSlotTests {
    static let modelID = NemotronSuperServingPolicy.modelID

    final class Recorder: @unchecked Sendable {
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

    struct Fixture {
        let loop: ProviderLoop
        let budget: GlobalKVCacheBudget
        let script: SuperOutputScript
        let directory: URL
    }

    /// Free memory the OS reports: everything, except for a while after
    /// `withhold(for:)`, as macOS does after a large unload.
    final class ReturningMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var returnsAt: ContinuousClock.Instant?
        func withhold(for duration: Duration) { lock.withLock { returnsAt = .now + duration } }
        func available(total: UInt64) -> UInt64 {
            lock.withLock { (returnsAt.map { ContinuousClock.now < $0 } ?? false) ? 1 << 28 : total }
        }
    }

    /// Weak references to the installed model and its head.
    final class InstallationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private weak var modelObject: AnyObject?
        private weak var headObject: AnyObject?
        func record(model: AnyObject?) { lock.withLock { modelObject = model } }
        func record(head: AnyObject) { lock.withLock { headObject = head } }
        var released: Bool { lock.withLock { modelObject == nil && headObject == nil } }
    }

    /// `totalGiB` bounds the process budget the LOAD claim and requests use.
    /// `physicalGiB` (default `totalGiB`) is the machine memory the slot
    /// loader sizes its prefix bank for, so no result depends on the host.
    static func fixture(mode: MTPMode, totalGiB: UInt64 = 64, physicalGiB: UInt64? = nil,
                        memory: ReturningMemory? = nil,
                        probe: InstallationProbe? = nil) async throws -> Fixture {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: totalGiB << 30, active: 0, cache: 0,
                  systemAvailable: memory?.available(total: totalGiB << 30) ?? totalGiB << 30)
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
            loader(tokenizer: TokenizerHandle(SuperScriptedTokenizer(script: script)), template: template,
                   physicalBytes: (physicalGiB ?? totalGiB) << 30, probe: probe),
            environment: [:])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("super-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(#"{"model_type":"nemotron_h_omni"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        return Fixture(loop: loop, budget: budget, script: script, directory: directory)
    }

    /// The latent-MoE fixture and its embedded head, staged through the real
    /// transaction under the provider's grant, admission and environment.
    /// 64-wide attention heads, the paged kernels' minimum: the managed plan
    /// selects paged KV.
    static func loader(tokenizer: TokenizerHandle, template: Data, physicalBytes: UInt64,
                       probe: InstallationProbe? = nil) -> NemotronSuperSlotLoader {
        NemotronSuperSlotLoader(pinned: false, physicalBytes: physicalBytes,
                                kvBytesPerToken: { _ in 64 }) { request in
            try await SuperMTPInstalledFixture.$attentionHeadDim.withValue(64) {
                try await load(request, tokenizer: tokenizer, template: template, probe: probe)
            }
        }
    }

    private static func load(_ request: NemotronSuperSlotLoader.Request, tokenizer: TokenizerHandle,
                             template: Data, probe: InstallationProbe?) async throws -> NemotronSuperSlotOwner {
        let fixture = try SuperMTPInstalledFixture(
            radioDimensions: SuperMTPInstalledFixture.encodedImageTower).staging()
        let staging = NemotronSuperLocalLoad.Staging(source: fixture.source, install: {
            let installed = try fixture.install($0, $1, $2)
            probe?.record(model: installed.model)
            return installed
        }, head: fixture.head.map { head in
            .init(quote: head.quote, load: {
                let module = try head.load($0, $1, $2)
                probe?.record(head: module)
                return module
            })
        })
        let tensorBytes = staging.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
            maxContextLength: 1024, defaultMaxTokens: 16)
        let transaction = NemotronSuperLocalLoad(budget: request.budget)
        let bridge = try await transaction.load(staging: { staging }, tokenizer: tokenizer,
            eosTokenIDs: [], sizing: sizing, kvBytesCapacity: request.kvBytesCapacity,
            admissionKVBytes: request.admissionKVBytes, backendAllowanceBytes: 1 << 20,
            modelID: request.modelID, environment: request.environment,
            physicalBytes: request.physicalBytes)
        return try await NemotronSuperSlotOwner(transaction: transaction, bridge: bridge,
            tokenizer: tokenizer, sizing: sizing, templateBytes: template)
    }

    static func body(_ pieces: [String], script: SuperOutputScript,
                             _ extra: [String: Any] = [:]) throws -> Data {
        script.set(pieces)
        var value: [String: Any] = ["model": modelID, "stream": true, "temperature": 0,
            "max_tokens": pieces.count, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hi"]]]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// One encrypted coordinator request: the decrypted SSE and its terminal.
    static func send(_ body: Data, to loop: ProviderLoop, recorder: Recorder,
        consumer: NodeKeyPair, scope: String? = "tenant-a", deadline seconds: Int = 60,
        whileRunning: (@Sendable (String) async -> Void)? = nil
    ) async throws -> (sse: String, terminal: OutboundMessage) {
        let id = "super-coordinator-\(UUID().uuidString)"
        let ciphertext = try consumer.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes,
                                              plaintext: body)
        await loop.handleInferenceRequest(requestId: id, ciphertext: ciphertext,
            senderPublicKey: consumer.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: scope, send: SendHandle(recorder.record))
        if let whileRunning { await whileRunning(id) }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while recorder.terminal(id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let terminal = try #require(recorder.terminal(id))
        let frames = try recorder.chunks(id).map { String(decoding: try consumer.decryptPayload($0), as: UTF8.self) }
        return (frames.joined(), terminal)
    }

    static func usage(_ terminal: OutboundMessage) -> UsageInfo? {
        if case .inferenceComplete(_, let usage, _, _, _, _) = terminal { return usage }
        return nil
    }

    static func failure(_ terminal: OutboundMessage) -> InferenceFailure? {
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
        // Forced tool_choice: required and named calls validate; plain text fails closed.
        let named: [String: Any] = ["type": "function", "function": ["name": "get_weather"]]
        for choice in ["required", named] as [Any] {
            let forced = try await Self.send(Self.body(call, script: script,
                ["tools": [weather], "tool_choice": choice]), to: loop, recorder: recorder, consumer: consumer)
            #expect(SuperSSE(forced.sse).toolCalls.map(\.name) == ["get_weather"], "\(forced.terminal)")
        }
        let ignored = try await Self.send(Self.body(["Sure", "."], script: script,
            ["tools": [weather], "tool_choice": "required"]), to: loop, recorder: recorder, consumer: consumer)
        #expect(Self.failure(ignored.terminal)?.statusCode == 422, "\(ignored.terminal)")
        // An undecodable image and unhonored controls are refused.
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

    /// Unload releases the owner, engine, model and head, and the slot loads
    /// again while the OS is still returning the unloaded pages.
    @Test(.timeLimit(.minutes(3)))
    func unloadReleasesTheOwnerAndTheSlotReloadsWhileMemoryReturns() async throws {
        let memory = ReturningMemory(), probe = InstallationProbe()
        let fixture = try await Self.fixture(mode: .auto, memory: memory, probe: probe)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        for round in 1...2 {
            // From round 2 the OS has not yet returned the unloaded pages.
            if round > 1 { memory.withhold(for: .milliseconds(300)) }
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
            weak var owner: NemotronSuperSlotOwner?
            weak var engine: EngineV2?
            do {
                let strong = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
                let ownedEngine = await strong.bridge.ownedEngine
                owner = strong; engine = ownedEngine as? EngineV2
                #expect(engine != nil && !probe.released)
                let text = try await Self.send(Self.body(["a", "b"], script: script), to: loop,
                                               recorder: recorder, consumer: consumer)
                #expect(SuperSSE(text.sse).content == "ab", "round \(round)")
                let image = try await Self.send(Self.imageBody(["c"], script: script, maxTokens: 1), to: loop,
                                                recorder: recorder, consumer: consumer)
                #expect(SuperSSE(image.sse).content == "c", "round \(round)")
            }
            #expect(await loop.unloadModel(Self.modelID))
            let deadline = ContinuousClock.now + .seconds(5)
            while owner != nil || engine != nil || !probe.released, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(owner == nil && engine == nil && probe.released, "round \(round)")
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
        }
        // Outside the retirement window the same shortfall is still refused.
        try await Task.sleep(for: NativeMemoryRetirementWindow.maximumDuration)
        memory.withhold(for: .seconds(2))
        await #expect(throws: InferenceError.self) {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
        }
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
        // The ordinary load gate passes; the managed claim's 22 GiB KV headroom does not.
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

    /// The slot's planned bank is the bank its builder builds and holds,
    /// whatever machine memory the loader sizes it for: the fixture owner's
    /// generic 1 GiB bank on a 64 GiB and a 256 GiB machine.
    @Test(.timeLimit(.minutes(2)), arguments: [64, 256] as [UInt64])
    func plannedBankIsHeldWhateverTheMachine(physicalGiB: UInt64) async throws {
        let fixture = try await Self.fixture(mode: .auto, physicalGiB: physicalGiB)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                                 revisionDirectory: fixture.directory)
        let banks = await fixture.budget.reservationBytesSnapshot()
            .filter { NemotronSuperLocalPrefixCache.isBankReservationID($0.key) }
        #expect(banks.count == 1 && banks.values.first == 1 << 30, "\(banks)")
        #expect(await fixture.loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// Every refusal the managed load raises itself is recorded by name; only
    /// an error from outside the load keeps the generic reason.
    @Test func loadRefusalsAreRecordedByName() {
        let generic = "native construction was refused"
        let named: [(any Error, String)] = [
            (NemotronSuperLocalBridgeBuilder.Failure.loadAdmissionLost,
             "the LOAD claim no longer fit after installation"),
            (NemotronSuperLocalKVBackend.Failure.decodeRowsRefused, "insufficient memory for the decode rows"),
            (NemotronSuperLocalPrefixCache.Failure.unavailable, "the engine did not construct the prefix bank"),
            (NemotronSuperLocalPrefixCache.Failure.bankRefused, "insufficient memory for the prefix bank"),
            (NemotronSuperLocalPrefill.Failure.laneRefused, "insufficient memory for the prefill lane"),
            (NemotronSuperLocalLoad.Failure.capacity, "insufficient memory at LOAD admission"),
        ]
        for (error, reason) in named {
            #expect(ProviderLoop.nemotronSuperLoadRefusalReason(error) == reason, "\(error)")
        }
        #expect(ProviderLoop.nemotronSuperLoadRefusalReason(URLError(.unknown)) == generic)
    }
}

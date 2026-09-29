import Foundation
import MLX
import MLXNN
import MLXLMServer
import XCTest
@testable import MLXLMCommon
@testable import ProviderCore

private actor NativeLoopGate {
    private let onEntry: @Sendable () -> Void
    private var entered = false
    private var open = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    init(onEntry: @escaping @Sendable () -> Void = {}) { self.onEntry = onEntry }
    func enterAndWait() async {
        entered = true
        onEntry()
        let ready = observers; observers = []
        for observer in ready { observer.resume() }
        if open { return }
        await withCheckedContinuation { blocked.append($0) }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func hasEntered() -> Bool { entered }
    func release() {
        open = true
        let ready = blocked; blocked = []
        for waiter in ready { waiter.resume() }
    }
}

private struct NativeLoopTestFailure: Error {}

// Admission-only peer: never generates or stands in for a real-model smoke pass.
// The MiMo failure below still uses the actual native fixture/owner/retirement.
private final class NativeFaultPeerModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
private struct NativeFaultPeerProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw NativeLoopTestFailure() }
}

private final class NativeFaultPeerEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    private var kvBytesCapacity = 1 << 20
    var submissions: Int { lock.withLock { submitted } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submitted += 1 }
        return AsyncStream {
            $0.yield(.finished(reason: .stop, usage: CBv2Usage(promptTokens: 1, completionTokens: 0)))
            $0.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: kvBytesCapacity, activeTokens: 0)
        }
    }
    func updateKVBytesCapacity(_ bytes: Int) { lock.withLock { kvBytesCapacity = bytes } }
    func shutdown() async {}
}

private func nativeFaultPeerSubmitErrors(
    _ bridge: EngineV2Bridge, modelID: String, requestID: String
) async -> [String] {
    let request = ChatCompletionRequest(model: modelID,
        messages: [ChatMessage(role: "user", content: "peer admission")], max_tokens: 1)
    let stream = await bridge.submitTokenized(promptTokens: [1], request: request,
        requestId: requestID, cacheEnabled: false)
    var errors: [String] = []
    for await event in stream {
        if case .error(let message) = event { errors.append(message) }
    }
    return errors
}

private final class NativeLoopObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    func mark() { lock.withLock { observed = true } }
    var value: Bool { lock.withLock { observed } }
}

private final class NativeLoopControllerJoinObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String?] = []
    func record(_ id: String?) { lock.withLock { identifiers.append(id) } }
    var values: [String?] { lock.withLock { identifiers } }
}

private extension ProviderLoop {
    func nativeLifetimeBoundary(_ body: (@Sendable (String) async throws -> Void)?) {
        nativeMiMoBoundaryForTesting = body
    }
    func nativeLifetimeSlotCount() -> Int { modelSlots.count }
    func nativeLifetimeSlotIDs() -> [String] { modelSlots.keys.sorted() }
    func nativeLifetimeInstallRoutingPeer(_ id: String, runtime: EngineV2Runtime) async
        -> (bridge: EngineV2Bridge, engine: NativeFaultPeerEngine) {
        let engine = NativeFaultPeerEngine()
        let tokenizer = StubBridgeTokenizer()
        let bridge = EngineV2Bridge(engine: engine, modelId: id,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [])
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: id), model: NativeFaultPeerModel(),
            processor: NativeFaultPeerProcessor(), tokenizer: tokenizer))
        installModelSlotForTesting(modelId: id, container: container,
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            modelType: "non-native-routing-fixture")
        await runtime.register(modelId: id, bridge: bridge)
        return (bridge, engine)
    }
    func nativeLifetimeAttachUnstartedCoordinator() -> CoordinatorClient {
        let client = CoordinatorClient(config: .init(url: "ws://127.0.0.1:0/not-started",
            hardware: loopConfig.hardware, models: [], backendName: "mlx-swift"),
            stats: stats, state: state, liveAPNsToken: { nil })
        // Never call start(): real shutdown state is observable without a
        // socket, authentication, APNs lookup or mock coordinator behavior.
        coordinatorClient = client
        return client
    }
    func nativeLifetimeHasLease(_ id: UUID, modelID: String) -> Bool {
        nativeMiMoConsumerLeases[modelID]?[id] != nil
    }
    func nativeLifetimeJoinObserver(modelID: String) async {
        let task = nativeMiMoRetirementTasks[modelID]
        await task?.value
    }
    func nativeLifetimeInstallBlockedCoordinatorTask(
        requestID: String, modelID: String, gate: NativeLoopGate
    ) throws -> Task<Void, Never> {
        let entry = try nativeLifetimeRegistryEntry(modelID)
        // A real outer Task retains its actual resolved-entry alias until its
        // frame returns. No manual native retention helper is called here.
        let task = Task { [weak self, entry] in
            await gate.enterAndWait()
            await self?.finishInflightRequest(requestId: requestID)
            withExtendedLifetime(entry) {}
        }
        requestToModel[requestID] = modelID
        inflightTasks[requestID] = task
        powerAssertion.acquire()
        return task
    }
    func nativeLifetimeCancellationState(requestID: String, modelID: String) -> (Bool, Bool, Int) {
        (requestToModel[requestID] != nil, inflightTasks[requestID] != nil,
         nativeMiMoHostConsumers[modelID]?.count ?? 0)
    }
    func nativeLifetimeRegistryEntry(_ modelID: String) throws -> MultiModelBatchSchedulerEngine.ModelRegistryEntry {
        guard let slot = modelSlots[modelID] else { throw NativeLoopTestFailure() }
        return .init(tokenizer: slot.tokenizer, modelType: slot.modelType, container: slot.container,
                     diffusionContainer: slot.modelContainer.diffusion, isVLM: slot.isVLM,
                     engineV2Bridge: slot.engineV2, visionGate: slot.visionGate(kvBudget: kvBudget))
    }
}

/// Source-prepared caller tests. Metadata cases use actual core permits/receipts
/// with an explicit synthetic usage oracle. Native cases use the real strict
/// bounded model, production slot factory, tracked EngineV2 and native leases.
final class ProviderLoopNativeMiMoLifetimeTests: XCTestCase {
    private let modelID = "synthetic-native-mimo-loop"
    private func metadataLane() throws {
        guard ProcessInfo.processInfo.environment["MIMO_V26_PROVIDER_LIFETIME_METADATA_TESTS"] == "1" else {
            throw XCTSkip("Explicit metadata/fixture opt-in required")
        }
    }
    private func nativeLane(fault: String? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1",
            environment["MIMO_V26_PROVIDER_LIFETIME_NATIVE_TESTS"] == "1" else {
            throw XCTSkip("Requires a separately authorized exclusive native lane")
        }
        guard environment["MIMO_V26_PROVIDER_LIFETIME_FAULT_CASE"] == fault else {
            throw XCTSkip("Retained-fault selector must run alone in its own process")
        }
        guard environment["DARKBLOOM_PREFIX_CACHE"] == "0",
            environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] == "0" else {
            throw XCTSkip("Explicit cold native profile required; no cache credentials are permitted")
        }
    }
    private func budget(native: Bool = false) -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 0.90, activationReserveBytes: 11 * (1 << 29),
            configReserveBytes: 4 << 30, memorySnapshot: {
                if native {
                    let memory = Memory.snapshot()
                    return .init(total: ProcessInfo.processInfo.physicalMemory,
                        active: UInt64(max(0, memory.activeMemory)), cache: UInt64(max(0, memory.cacheMemory)),
                        systemAvailable: .max)
                }
                return .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
            })
    }
    private func loop(registry: MiMoV26NativeLoadRegistry, budget: GlobalKVCacheBudget) throws -> ProviderLoop {
        let configuration = ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40,
                memoryBandwidthGbs: 546), models: [],
            config: ProviderConfig(provider: ProviderSettings(name: "native-loop-lifetime-test", memoryReserveGB: 4),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: configuration, attestationSigner: nil,
            kvBudgetForTesting: budget, nativeMiMoRegistryForTesting: registry)
    }
    private func fixture() throws -> URL {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-provider-loop-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        // Do not unlink files still referenced by a deliberately retained fault.
        let configuration = try Data(contentsOf: root.appendingPathComponent("config.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let manifest: [String: Any] = [
            "source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL", "source_revision": String(repeating: "a", count: 40),
            "source_config_sha256": MiMoV26ServingLoad.hash(configuration),
            "experts": "original E2M1/E8M0 codes, group 32, no requantization",
            "dense": "FP8 dequantized to BF16; original BF16 unchanged",
            "output_tensor_count": weights.count, "output_weight_bytes": try XCTUnwrap(metadata["total_size"]),
            "modality_tensor_counts": Dictionary(uniqueKeysWithValues: ["visual", "audio_encoder", "speech_embeddings"].map { prefix in
                (prefix, weights.keys.filter { $0.hasPrefix(prefix + ".") }.count)
            }),
            "mtp_embedded": ["architecture": "mimo_v2_nextn", "storage": "embedded", "num_layers": 3, "file": "model-mtp.safetensors"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("conversion_manifest.json"))
        let template = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
        let vocab = ["<unk>": 0, "<|im_end|>": 1, "<|im_start|>": 9, "<think>": 10, "</think>": 11, "x": 12, "<stop>": 13]
        let added: [[String: Any]] = vocab.filter { $0.key != "x" }.map { token, id in
            ["id": id, "content": token, "single_word": false, "lstrip": false, "rstrip": false, "normalized": false, "special": true]
        }
        let tokenizer: [String: Any] = ["version": "1.0", "truncation": NSNull(), "padding": NSNull(), "added_tokens": added,
            "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"], "post_processor": NSNull(), "decoder": ["type": "ByteLevel"],
            "model": ["type": "BPE", "vocab": vocab, "merges": [], "unk_token": "<unk>", "byte_fallback": false, "fuse_unk": false]]
        try JSONSerialization.data(withJSONObject: tokenizer).write(to: root.appendingPathComponent("tokenizer.json"))
        try JSONSerialization.data(withJSONObject: ["tokenizer_class": "PreTrainedTokenizerFast", "eos_token": "<|im_end|>",
            "unk_token": "<unk>", "chat_template": template]).write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data(template.utf8).write(to: root.appendingPathComponent("chat_template.jinja"))
        try JSONSerialization.data(withJSONObject: ["eos_token_id": [1, 13]]).write(to: root.appendingPathComponent("generation_config.json"))
        return root
    }
    private func loaded() async throws -> (ProviderLoop, MiMoV26ServingLoad, MiMoV26NativeLoadRegistry) {
        let registry = MiMoV26NativeLoadRegistry()
        let owner = try loop(registry: registry, budget: budget(native: true))
        await owner.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let directory = try fixture()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: directory))
        try await owner.loadNativeMiMoSlot(modelID: modelID, directory: directory, load: load,
            preparation: MiMoV26ServingLoad.preparation(mode: .off, externalPath: nil))
        return (owner, load, registry)
    }
    private func finish(_ owner: ProviderLoop, _ registry: MiMoV26NativeLoadRegistry) async throws {
        // Each retry follows an actual saved Task.value join, not a sleep or a
        // zero counter. Dedicated fault tests deliberately do not call this.
        for _ in 0..<4 {
            if await owner.retireNativeMiMoOwner(modelID: modelID) { return }
            guard !registry.hasRetainedFault else { throw NativeLoopTestFailure() }
            await owner.nativeLifetimeJoinObserver(modelID: modelID)
        }
        XCTFail("real native owner did not retire after actual consumer progress")
        throw NativeLoopTestFailure()
    }

    private func isolateLifecycleState(_ owner: ProviderLoop) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-loop-drain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await owner.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
    }

    /// Keep the real acquired payload and Scheduler in a bounded frame. Once
    /// this returns, neither can retain model aliases during owner retirement.
    private func completeActuallyBoundRequestAcrossGracefulDrain(
        _ owner: ProviderLoop, transaction: MiMoV26NativeLoadTransaction
    ) async throws {
        let modelID = self.modelID
        let acquired = try await owner.acquireModelForLocal(modelID)
        let lease = try XCTUnwrap(acquired.nativeConsumerLease)
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        let originalLifecycle = try await owner.nativeMiMoLifecycleForLoad()
        let identity = try XCTUnwrap(ProcessIdentity.current())

        // This request was actually acquired and its real token/lease bound
        // BEFORE the drain; no accepted flag or synthetic counter admits it.
        let timedOut = await owner.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0))
        XCTAssertEqual(timedOut.outcome, .timedOut)
        let closed = await owner.nativeMiMoLifecycleClosed
        XCTAssertFalse(closed, "a graceful timeout must not revoke the actual published owner")
        XCTAssertNoThrow(try transaction.requireServingWorkAllowed())
        let stillOpen = try await owner.nativeMiMoLifecycleForLoad()
        XCTAssertEqual(stillOpen, originalLifecycle, "no new lifecycle or bypass token is created")

        // The OS/schedule wrapper must preserve the same accepted work, too.
        let stopped = await owner.drainAndShutdown(timeoutSeconds: 0)
        XCTAssertFalse(stopped)
        XCTAssertNoThrow(try transaction.requireServingWorkAllowed())
        do { _ = try await owner.acquireModelForLocal(modelID); XCTFail("new acquisition entered a graceful drain") }
        catch { XCTAssertTrue(error is MultiModelBatchSchedulerEngineError) }

        // Continue the SAME real pre-drain payload through actual preparation,
        // native Bridge/EngineV2 submission, event forwarding and lease release.
        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquired },
            tokenizerProvider: { _ in .init(tokenizer: acquired.tokenizer, modelType: acquired.modelType) },
            availableModels: { [modelID] in [modelID] }, defaultMaxTokens: 2)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": "x"]], "max_tokens": 2, "temperature": 0]))
        let stream = try await scheduler.streamChatCompletion(request: request)
        var terminals = 0
        for try await event in stream {
            if case .info(let info) = event {
                terminals += 1
                XCTAssertGreaterThan(info.promptTokens, 0)
                XCTAssertGreaterThan(info.completionTokens, 0)
                XCTAssertTrue(info.stopReason == "stop" || info.stopReason == "length")
            }
        }
        await lease.joinFromOutside()
        XCTAssertEqual(terminals, 1)
        XCTAssertEqual(lease.snapshot().phase, .completed)
        XCTAssertNoThrow(try transaction.requireServingWorkAllowed())
    }

    private func disposeActuallyBoundRequestAfterForcedDrain(
        _ owner: ProviderLoop, transaction: MiMoV26NativeLoadTransaction
    ) async throws {
        let modelID = self.modelID
        let acquired = try await owner.acquireModelForLocal(modelID)
        let lease = try XCTUnwrap(acquired.nativeConsumerLease)
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        let identity = try XCTUnwrap(ProcessIdentity.current())
        // The real force path has its existing bounded five-second wait. Its
        // cancellation cannot pretend this armed handoff is already disposed.
        let forced = await owner.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0, force: true))
        XCTAssertEqual(forced.outcome, .forced)
        let closed = await owner.nativeMiMoLifecycleClosed
        XCTAssertTrue(closed)
        XCTAssertThrowsError(try transaction.requireServingWorkAllowed())
        XCTAssertNotEqual(transaction.snapshot().phase, .retired)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        let stoppedWithHeldHandoff = await owner.drainAndShutdown(timeoutSeconds: 0)
        XCTAssertFalse(stoppedWithHeldHandoff, "forced status is not actual native retirement")

        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquired },
            tokenizerProvider: { _ in .init(tokenizer: acquired.tokenizer, modelType: acquired.modelType) },
            availableModels: { [modelID] in [modelID] }, defaultMaxTokens: 2)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": "x"]], "max_tokens": 1]))
        do { _ = try await scheduler.streamChatCompletion(request: request); XCTFail("forced owner accepted pre-submit work") }
        catch { XCTAssertTrue(error is NativeLocalConsumerOwnershipError || error is CancellationError) }
        await lease.joinFromOutside()
        XCTAssertEqual(lease.snapshot().phase, .completed)
    }

    func testOneLoopLifecycleIsStableAndStopPreventsFreshToken() async throws {
        try metadataLane()
        let registry = MiMoV26NativeLoadRegistry()
        let owner = try loop(registry: registry, budget: budget())
        let first = try await owner.nativeMiMoLifecycleForLoad()
        let second = try await owner.nativeMiMoLifecycleForLoad()
        XCTAssertEqual(first, second)
        await owner.closeNativeMiMoLifecycle()
        do { _ = try await owner.nativeMiMoLifecycleForLoad(); XCTFail("stop minted a fresh per-load lifecycle") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOtherLoopCannotRegrowClosingNativePermitUntilActualNoWorkRetirement() async throws {
        try metadataLane()
        let registry = MiMoV26NativeLoadRegistry(), sharedBudget = budget()
        let first = try loop(registry: registry, budget: sharedBudget)
        let other = try loop(registry: registry, budget: sharedBudget)
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        let transaction = try await first.claimNativeMiMoLoad(load, modelID: modelID)
        XCTAssertGreaterThan(sharedBudget.processLedger.snapshot().chargedBytes, 0)
        load.revoke()
        let blocked = await other.nativeMiMoAllowsReclamation()
        XCTAssertFalse(blocked)
        let retired = await first.retireNativeMiMoOwner(modelID: modelID)
        XCTAssertTrue(retired)
        XCTAssertEqual(transaction.snapshot().phase, .retired)
        XCTAssertEqual(sharedBudget.processLedger.snapshot().chargedBytes, 0)
        let allowed = await other.nativeMiMoAllowsReclamation()
        XCTAssertTrue(allowed)
    }

    func testDuplicateNativeClaimDoesNotRevokeOriginalActualPermit() async throws {
        try metadataLane()
        let registry = MiMoV26NativeLoadRegistry(), actualBudget = budget()
        let owner = try loop(registry: registry, budget: actualBudget)
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        let transaction = try await owner.claimNativeMiMoLoad(load, modelID: modelID)
        let before = try XCTUnwrap(transaction.snapshot().permit?.ownerState)
        do { _ = try await owner.claimNativeMiMoLoad(load, modelID: modelID); XCTFail("duplicate claim accepted") }
        catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .warmRebuildUnsupported) }
        XCTAssertNoThrow(try transaction.recheckSetup())
        XCTAssertEqual(actualBudget.processLedger.state(for: before.owner), before)
        let retired = await owner.retireNativeMiMoOwner(modelID: modelID)
        XCTAssertTrue(retired)
    }

    func testActualSealedCandidateCannotPublishAfterOwnerStop() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), actualBudget = budget(native: true)
        let owner = try loop(registry: registry, budget: actualBudget)
        await owner.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let entered = expectation(description: "real candidate reached publication boundary")
        let directory = try fixture(), gate = NativeLoopGate(onEntry: { entered.fulfill() })
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: directory))
        await owner.nativeLifetimeBoundary { point in if point == "beforePublication" { await gate.enterAndWait() } }
        let modelID = self.modelID
        let task = Task {
            try await owner.loadNativeMiMoSlot(modelID: modelID, directory: directory, load: load,
                preparation: MiMoV26ServingLoad.preparation(mode: .off, externalPath: nil))
        }
        await fulfillment(of: [entered], timeout: 60)
        guard await gate.hasEntered() else {
            task.cancel(); await gate.release()
            _ = Unmanaged.passRetained(registry)
            XCTFail("native candidate never reached its real publication boundary")
            throw NativeLoopTestFailure()
        }
        let beforeSlots = await owner.nativeLifetimeSlotCount()
        XCTAssertEqual(beforeSlots, 0)
        XCTAssertGreaterThan(actualBudget.processLedger.snapshot().chargedBytes, 0)
        await owner.closeNativeMiMoLifecycle()
        await gate.release()
        do { try await task.value; XCTFail("stopped candidate published") } catch {}
        await owner.nativeLifetimeBoundary(nil)
        try await finish(owner, registry)
        let afterSlots = await owner.nativeLifetimeSlotCount()
        XCTAssertEqual(afterSlots, 0)
        XCTAssertEqual(actualBudget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testActualNativeSlotServesAndWarmDuplicateCannotBuildAgain() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        let transaction = try XCTUnwrap(load.transaction)
        let before = transaction.snapshot()
        let actualBridge = await owner.slotBridgeForTesting(modelId: modelID)
        let bridge = try XCTUnwrap(actualBridge)
        let actualEngine = await bridge.ownedEngine as? EngineV2
        let engine = try XCTUnwrap(actualEngine)
        let submission = try engine.submitWithNativeRetirement(.init(id: .init(41), promptTokens: [9, 12],
            sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false))
        var tokens: [Int] = [], reason: CBv2FinishReason?
        for await event in submission.events {
            switch event { case .delta(_, let emitted, _): tokens += emitted; case .finished(let value, _): reason = value }
        }
        await submission.retirement.wait()
        XCTAssertEqual(tokens.count, 2); XCTAssertEqual(reason, .length)
        do {
            try await owner.loadNativeMiMoSlot(modelID: modelID, directory: load.plan.canonicalRoot, load: load,
                preparation: MiMoV26ServingLoad.preparation(mode: .off, externalPath: nil))
            XCTFail("native warm pipeline rebuilt")
        } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .warmRebuildUnsupported) }
        XCTAssertEqual(transaction.snapshot().constructionEpoch, before.constructionEpoch)
        XCTAssertEqual(transaction.snapshot().phase, .published)
        let sameBridge = await owner.slotBridgeForTesting(modelId: modelID)
        XCTAssertTrue(sameBridge === bridge)
        try await finish(owner, registry)
        XCTAssertEqual(transaction.snapshot().phase, .retired)
    }

    func testTypedSDKDrainPrecedesExactOuterConsumerJoin() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        let entered = expectation(description: "dependent outer Task entered")
        let dependency = NativeLoopGate(onEntry: { entered.fulfill() })
        let observed = NativeLoopObservation()
        let drained = expectation(description: "actual SDK drain reached before dependent Task join")
        let consumer = Task { await dependency.enterAndWait() }
        await fulfillment(of: [entered], timeout: 10)
        guard await dependency.hasEntered() else { throw NativeLoopTestFailure() }
        await owner.retainNativeMiMoHostConsumer(consumer, modelID: modelID)
        await owner.nativeLifetimeBoundary { point in
            if point == "afterSDKDrainBeforeHostJoin" { observed.mark(); drained.fulfill(); await dependency.release() }
        }
        let modelID = self.modelID
        let retirement = Task { await owner.retireNativeMiMoOwner(modelID: modelID) }
        await fulfillment(of: [drained], timeout: 10)
        guard observed.value else {
            // Escape the artificial dependency hold only after recording failure;
            // this is not a fabricated successful SDK or retirement outcome.
            await dependency.release()
            retirement.cancel()
            XCTFail("caller joined the dependent host Task before actual SDK drain")
            throw NativeLoopTestFailure()
        }
        let first = await retirement.value
        if !first { await owner.nativeLifetimeJoinObserver(modelID: modelID) }
        await owner.nativeLifetimeBoundary(nil)
        await consumer.value
        try await finish(owner, registry)
        XCTAssertEqual(load.transaction?.snapshot().phase, .retired)
    }

    func testActualCancellationRetainsOuterTaskBeforeAssociationErasureSuspends() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), actualBudget = budget(native: true)
        let owner = try loop(registry: registry, budget: actualBudget)
        await owner.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let directory = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: directory))
        try await owner.loadNativeMiMoSlot(modelID: modelID, directory: directory, load: load,
            preparation: MiMoV26ServingLoad.preparation(mode: .off, externalPath: nil))
        let transaction = try XCTUnwrap(load.transaction)
        let outerEntered = expectation(description: "real outer Task holds its actual resolved entry")
        let outerGate = NativeLoopGate(onEntry: { outerEntered.fulfill() })
        let requestID = "native-cancel-association-handoff"
        let outer = try await owner.nativeLifetimeInstallBlockedCoordinatorTask(
            requestID: requestID, modelID: modelID, gate: outerGate)
        await fulfillment(of: [outerEntered], timeout: 10)
        guard await outerGate.hasEntered() else {
            await outerGate.release(); outer.cancel()
            _ = Unmanaged.passRetained(registry)
            XCTFail("outer Task never reached its owned alias hold")
            throw NativeLoopTestFailure()
        }

        let erasureReached = expectation(description: "actual cancellation removed association before capacity await")
        let cancellationGate = NativeLoopGate(onEntry: { erasureReached.fulfill() })
        // Publication already settles the cold-load allowance through actual
        // finishSetupAfterAccounting. A host-only outer frame adds no C. Keep
        // the observed charge/coverage basis; do not invent a positive charge
        // or equate allocator usage/owner count with retained object lifetime.
        let beforeCancelLedger = actualBudget.processLedger.snapshot()
        let beforeCancelPermitState = transaction.snapshot().permit?.ownerState
        let cancellation = Task {
            await owner.handleCancellation(requestId: requestID, receivedFromCoordinator: false,
                afterNativeCancellationAssociationErasureForTesting: { await cancellationGate.enterAndWait() })
        }
        await fulfillment(of: [erasureReached], timeout: 10)
        guard await cancellationGate.hasEntered() else {
            await cancellationGate.release(); await outerGate.release()
            cancellation.cancel(); outer.cancel()
            _ = Unmanaged.passRetained(registry)
            XCTFail("actual handleCancellation never reached the association-erasure boundary")
            throw NativeLoopTestFailure()
        }

        let held = await owner.nativeLifetimeCancellationState(requestID: requestID, modelID: modelID)
        XCTAssertFalse(held.0, "the actual request association is already erased")
        XCTAssertTrue(held.1, "legacy Task removal still follows capacity refresh")
        XCTAssertEqual(held.2, 1, "exact Task handoff must precede the first post-erasure suspension")
        XCTAssertFalse(outer.isCancelled, "do not move Task.cancel ahead of the original capacity ordering")

        // No handoff helper is invoked by this test: the actual cancellation
        // method must have retained the actual outer Task before this real
        // typed tiny-native retirement can lose its map association.
        let first = await owner.retireNativeMiMoOwner(modelID: modelID)
        XCTAssertFalse(first, "SDK quiescence cannot retire a still-held outer Task")
        XCTAssertNotEqual(transaction.snapshot().phase, .retired)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertTrue(load.transaction === transaction)
        XCTAssertTrue(registry.retainedTransactionIDs.contains(transaction.id))
        let heldLedger = actualBudget.processLedger.snapshot()
        XCTAssertEqual(heldLedger.chargedBytes, beforeCancelLedger.chargedBytes)
        XCTAssertEqual(heldLedger.materializedBytes, beforeCancelLedger.materializedBytes)
        XCTAssertEqual(heldLedger.unmaterializedBytes, beforeCancelLedger.unmaterializedBytes)
        XCTAssertEqual(transaction.snapshot().permit?.ownerState, beforeCancelPermitState)

        await cancellationGate.release()
        await cancellation.value
        XCTAssertTrue(outer.isCancelled, "the original final Task.cancel still runs")
        let cancelled = await owner.nativeLifetimeCancellationState(requestID: requestID, modelID: modelID)
        XCTAssertFalse(cancelled.0)
        XCTAssertFalse(cancelled.1)
        XCTAssertEqual(cancelled.2, 1, "cancellation is not actual Task completion")
        let stillHeld = await owner.retireNativeMiMoOwner(modelID: modelID)
        XCTAssertFalse(stillHeld)
        XCTAssertNotEqual(transaction.snapshot().phase, .retired)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertTrue(load.transaction === transaction)
        XCTAssertTrue(registry.retainedTransactionIDs.contains(transaction.id))
        let cancelledLedger = actualBudget.processLedger.snapshot()
        XCTAssertEqual(cancelledLedger.chargedBytes, beforeCancelLedger.chargedBytes)
        XCTAssertEqual(cancelledLedger.materializedBytes, beforeCancelLedger.materializedBytes)
        XCTAssertEqual(cancelledLedger.unmaterializedBytes, beforeCancelLedger.unmaterializedBytes)
        XCTAssertEqual(transaction.snapshot().permit?.ownerState, beforeCancelPermitState)

        // Release the real frame only now, then join its exact Task and the
        // owner's saved join observer before asking the core to clean up.
        await outerGate.release()
        await outer.value
        await owner.nativeLifetimeJoinObserver(modelID: modelID)
        do { try await finish(owner, registry) }
        catch { _ = Unmanaged.passRetained(registry); throw error }
        XCTAssertEqual(transaction.snapshot().phase, .retired)
        XCTAssertEqual(actualBudget.processLedger.snapshot().chargedBytes, 0)
        let finished = await owner.nativeLifetimeCancellationState(requestID: requestID, modelID: modelID)
        XCTAssertFalse(finished.0)
        XCTAssertFalse(finished.1)
        XCTAssertEqual(finished.2, 0)
    }

    func testActualLocalAcquisitionRetainsSameLeaseAndClosedHandoffIsNotCompletion() async throws {
        try nativeLane()
        let modelID = self.modelID
        let (owner, load, registry) = try await loaded()
        let acquired = try await owner.acquireModelForLocal(modelID)
        let lease = try XCTUnwrap(acquired.nativeConsumerLease)
        let retained = await owner.nativeLifetimeHasLease(lease.id, modelID: modelID)
        XCTAssertTrue(retained)
        let first = await owner.retireNativeMiMoOwner(modelID: modelID)
        XCTAssertFalse(first, "bound but unconsumed acquisition is not a joined consumer")
        XCTAssertNotEqual(load.transaction?.snapshot().phase, .retired)
        // Transfer the real unused payload to the real Scheduler. It must refuse
        // the closed lease and perform its own typed cold disposal, not a test
        // calling a fabricated completion hook.
        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquired },
            tokenizerProvider: { _ in .init(tokenizer: acquired.tokenizer, modelType: acquired.modelType) },
            availableModels: { [modelID] in [modelID] },
            defaultMaxTokens: 2)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": "x"]], "max_tokens": 1]))
        do { _ = try await scheduler.streamChatCompletion(request: request); XCTFail("closed native consumer started") }
        catch { XCTAssertTrue(error is NativeLocalConsumerOwnershipError || error is CancellationError) }
        await lease.joinFromOutside()
        try await finish(owner, registry)
        XCTAssertEqual(load.transaction?.snapshot().phase, .retired)
    }

    func testGracefulNativeDrainPreservesActuallyBoundPreSubmitRequest() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        try await isolateLifecycleState(owner)
        let transaction = try XCTUnwrap(load.transaction)
        do {
            try await completeActuallyBoundRequestAcrossGracefulDrain(owner, transaction: transaction)
            // The accepted frame is now gone. Successful real teardown closes
            // the lifecycle, and any host-pending retry follows its exact join.
            var stopped = await owner.drainAndShutdown(timeoutSeconds: 1)
            if !stopped {
                await owner.nativeLifetimeJoinObserver(modelID: modelID)
                try await finish(owner, registry)
                stopped = await owner.drainAndShutdown(timeoutSeconds: 1)
            }
            XCTAssertTrue(stopped)
            XCTAssertEqual(transaction.snapshot().phase, .retired)
            let closed = await owner.nativeMiMoLifecycleClosed
            XCTAssertTrue(closed)
            do { _ = try await owner.nativeMiMoLifecycleForLoad(); XCTFail("real stop reopened native generation") }
            catch { XCTAssertTrue(error is CancellationError) }
        } catch {
            // Keep the actual root, not only a numeric commitment, on unknown
            // native completion. This failed process must not run another cell.
            _ = Unmanaged.passRetained(registry)
            throw error
        }
    }

    func testForcedNativeDrainClosesGenerationBeforeBoundWorkCanSubmit() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        try await isolateLifecycleState(owner)
        let transaction = try XCTUnwrap(load.transaction)
        do {
            try await disposeActuallyBoundRequestAfterForcedDrain(owner, transaction: transaction)
            await owner.nativeLifetimeJoinObserver(modelID: modelID)
            try await finish(owner, registry)
            XCTAssertEqual(transaction.snapshot().phase, .retired)
            let stoppedAfterRetirement = await owner.drainAndShutdown(timeoutSeconds: 0)
            XCTAssertTrue(stoppedAfterRetirement)
            let closed = await owner.nativeMiMoLifecycleClosed
            XCTAssertTrue(closed)
        } catch {
            _ = Unmanaged.passRetained(registry)
            throw error
        }
    }

    /// The actual bound payload/Scheduler disappear when this helper returns,
    /// before the test requests final native-owner cleanup.
    private func exerciseConcurrentForcedControllerJoin(
        _ owner: ProviderLoop, transaction: MiMoV26NativeLoadTransaction,
        coordinator: CoordinatorClient
    ) async throws {
        let modelID = self.modelID
        let acquired = try await owner.acquireModelForLocal(modelID)
        let lease = try XCTUnwrap(acquired.nativeConsumerLease)
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        let forceEntered = expectation(description: "actual forced controller reached real SDK-drain boundary")
        let forceGate = NativeLoopGate(onEntry: { forceEntered.fulfill() })
        let heldOnce = NativeLoopObservation()
        await owner.nativeLifetimeBoundary { point in
            guard point == "afterSDKDrainBeforeHostJoin", !heldOnce.value else { return }
            heldOnce.mark()
            await forceGate.enterAndWait()
        }
        let identity = try XCTUnwrap(ProcessIdentity.current())
        let forcedRequest = ProviderDrainRequest(target: identity, timeoutSeconds: 0, force: true)
        let forced = Task { await owner.drainForLifecycle(request: forcedRequest) }
        await fulfillment(of: [forceEntered], timeout: 20)
        guard await forceGate.hasEntered() else {
            await forceGate.release(); await owner.nativeLifetimeBoundary(nil)
            forced.cancel()
            XCTFail("actual forced controller never reached its SDK-drain hold")
            throw NativeLoopTestFailure()
        }

        let joinObserved = expectation(description: "shutdown captured the same still-running forced controller")
        let join = NativeLoopControllerJoinObservation()
        let shutdown = Task {
            await owner.drainAndShutdown(timeoutSeconds: 0,
                beforeAwaitingExistingControllerForTesting: { requestID in
                    join.record(requestID)
                    joinObserved.fulfill()
                })
        }
        await fulfillment(of: [joinObserved], timeout: 10)
        guard !join.values.isEmpty else {
            await forceGate.release(); await owner.nativeLifetimeBoundary(nil)
            shutdown.cancel(); forced.cancel()
            XCTFail("shutdown did not capture an existing forced controller")
            throw NativeLoopTestFailure()
        }
        XCTAssertEqual(join.values, [forcedRequest.id])
        XCTAssertFalse(coordinator.shutdownRequested)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertNotEqual(transaction.snapshot().phase, .retired)

        // The observer ran AFTER actual Task capture and BEFORE its await.
        // Only now release the real controller to its normal .forced result.
        // The real native lease is still armed, so final retirement is pending.
        await forceGate.release()
        let forceResult = await forced.value
        let shutdownResult = await shutdown.value
        await owner.nativeLifetimeBoundary(nil)
        XCTAssertEqual(forceResult.requestID, forcedRequest.id)
        XCTAssertEqual(forceResult.outcome, .forced)
        XCTAssertFalse(shutdownResult, "a joined .forced controller is not native completion")
        XCTAssertFalse(coordinator.shutdownRequested, "do not close the real coordinator before native retirement")
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertNotEqual(transaction.snapshot().phase, .retired)

        // Dispose the SAME closed acquisition through the real Scheduler;
        // neither a forged phase nor an empty task map completes the handoff.
        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquired },
            tokenizerProvider: { _ in .init(tokenizer: acquired.tokenizer, modelType: acquired.modelType) },
            availableModels: { [modelID] in [modelID] }, defaultMaxTokens: 2)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": "x"]], "max_tokens": 1]))
        do { _ = try await scheduler.streamChatCompletion(request: request); XCTFail("forced acquisition submitted") }
        catch { XCTAssertTrue(error is NativeLocalConsumerOwnershipError || error is CancellationError) }
        await lease.joinFromOutside()
        XCTAssertEqual(lease.snapshot().phase, .completed)
    }

    func testShutdownJoiningHeldForcedControllerRefusesCoordinatorCloseUntilNativeRetirement() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        try await isolateLifecycleState(owner)
        let transaction = try XCTUnwrap(load.transaction)
        let coordinator = await owner.nativeLifetimeAttachUnstartedCoordinator()
        XCTAssertFalse(coordinator.shutdownRequested)
        do {
            try await exerciseConcurrentForcedControllerJoin(owner, transaction: transaction, coordinator: coordinator)
            await owner.nativeLifetimeJoinObserver(modelID: modelID)
            try await finish(owner, registry)
            XCTAssertEqual(transaction.snapshot().phase, .retired)
            XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
            XCTAssertFalse(coordinator.shutdownRequested)
            let stopped = await owner.drainAndShutdown(timeoutSeconds: 0)
            XCTAssertTrue(stopped)
            XCTAssertTrue(coordinator.shutdownRequested)
        } catch {
            await owner.nativeLifetimeBoundary(nil)
            _ = Unmanaged.passRetained(registry)
            throw error
        }
    }

    func testNativeFenceRefusalKeepsActualBundlePermitAndBlocksOtherOwnerReclaim() async throws {
        try nativeLane(fault: "testNativeFenceRefusalKeepsActualBundlePermitAndBlocksOtherOwnerReclaim")
        let registry = MiMoV26NativeLoadRegistry.shared, actualBudget = budget(native: true)
        let owner = try loop(registry: registry, budget: actualBudget)
        let runtime = EngineV2Runtime()
        await owner.setEngineV2RuntimeForTesting(runtime)
        defer { _ = Unmanaged.passRetained(registry) } // exact fault owner until process exit
        let peerID = "native-fault-routing-peer"
        let peer = await owner.nativeLifetimeInstallRoutingPeer(peerID, runtime: runtime)
        let beforeErrors = await nativeFaultPeerSubmitErrors(peer.bridge, modelID: peerID,
            requestID: "peer-before-native-fault")
        XCTAssertEqual(beforeErrors, [])
        XCTAssertEqual(peer.engine.submissions, 1)
        let directory = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: directory))
        await owner.nativeLifetimeBoundary { point in
            guard point == "afterNativeConstruction", let transaction = load.transaction,
                let bridge = transaction.registeredBridgeForRetirement(),
                let engine = await bridge.ownedEngine as? EngineV2 else { return }
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.nativeShutdownState?.beforeFenceForTesting = { _ in throw NativeLoopTestFailure() }
            }
            throw NativeLoopTestFailure() // actual construction completed; refuse publication
        }
        do {
            try await owner.loadNativeMiMoSlot(modelID: modelID, directory: directory, load: load,
                preparation: MiMoV26ServingLoad.preparation(mode: .off, externalPath: nil))
            XCTFail("failed completion published")
        } catch {}
        await owner.nativeLifetimeBoundary(nil)
        let transaction = try XCTUnwrap(load.transaction)
        XCTAssertTrue(registry.hasRetainedFault)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertGreaterThan(actualBudget.processLedger.snapshot().chargedBytes, 0)
        let allowed = await owner.nativeMiMoAllowsReclamation()
        let retired = await owner.retireNativeMiMoOwner(modelID: modelID)
        let slotIDs = await owner.nativeLifetimeSlotIDs()
        XCTAssertFalse(allowed)
        XCTAssertFalse(retired)
        XCTAssertEqual(slotIDs, [peerID], "failed native construction must not publish a slot")
        // A real SHARED retained native fault must not poison the already
        // resident peer's routing or its downstream bridge submit guards.
        let peerRejected = await owner.fastAdmissionReject(modelId: peerID)
        let nativeRejected = await owner.fastAdmissionReject(modelId: modelID)
        let coldRejected = await owner.fastAdmissionReject(modelId: "cold-routing-peer")
        XCTAssertFalse(peerRejected)
        XCTAssertTrue(nativeRejected)
        XCTAssertTrue(coldRejected, "new loads must remain fenced")
        let peerBridgeAllowed = await peer.bridge.canSubmitWithNativeOwner()
        let nativeBridge = try XCTUnwrap(transaction.registeredBridgeForRetirement())
        let nativeBridgeAllowed = await nativeBridge.canSubmitWithNativeOwner()
        XCTAssertTrue(peerBridgeAllowed)
        XCTAssertFalse(nativeBridgeAllowed)
        let afterErrors = await nativeFaultPeerSubmitErrors(peer.bridge, modelID: peerID,
            requestID: "peer-after-native-fault")
        XCTAssertEqual(afterErrors, [])
        XCTAssertEqual(peer.engine.submissions, 2, "the real peer bridge must reach engine admission")
        await owner.updateAggregateCapacity()
        let capacity = await owner.backendCapacityForTesting()
        XCTAssertEqual(capacity?.slots.first(where: { $0.model == peerID })?.state, "idle")
        XCTAssertEqual(capacity?.freeForLoadGb, 0)
        XCTAssertEqual(capacity?.loadUsableGb, 0)
        let reclaimAfterPeer = await owner.nativeMiMoAllowsReclamation()
        XCTAssertFalse(reclaimAfterPeer, "resident routing must not authorize reclamation")
        XCTAssertTrue(registry.hasRetainedFault)
        XCTAssertGreaterThan(actualBudget.processLedger.snapshot().chargedBytes, 0)
        _ = await runtime.unregister(modelId: peerID)
        await owner.removeModelSlotForTesting(modelId: peerID)
        // A failed native newcomer can be absent from modelSlots before
        // coordinator registration. The new startup cleanup must not treat
        // that empty slot map as permission to reclaim or report completion.
        await owner.setDaemonStateFileForTesting(directory.appendingPathComponent("startup-state.json"))
        let startupStopped = await owner.shutdownBeforeRegistration()
        XCTAssertFalse(startupStopped)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertTrue(registry.hasRetainedFault)
        XCTAssertGreaterThan(actualBudget.processLedger.snapshot().chargedBytes, 0)
        let retryStopped = await owner.shutdownBeforeRegistration()
        XCTAssertFalse(retryStopped)
        XCTAssertTrue(registry.hasRetainedFault)
    }

    func testStartupShutdownRetiresActualNativeSlotBeforeReportingCompletion() async throws {
        try nativeLane()
        let (owner, load, registry) = try await loaded()
        try await isolateLifecycleState(owner)
        let transaction = try XCTUnwrap(load.transaction)
        var stopped = await owner.shutdownBeforeRegistration()
        for _ in 0..<4 where !stopped {
            await owner.nativeLifetimeJoinObserver(modelID: modelID)
            stopped = await owner.shutdownBeforeRegistration()
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(transaction.snapshot().phase, .retired)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        let count = await owner.nativeLifetimeSlotCount()
        XCTAssertEqual(count, 0)
    }
}

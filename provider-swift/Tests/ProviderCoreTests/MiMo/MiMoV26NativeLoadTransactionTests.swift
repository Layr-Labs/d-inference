import Dispatch
import Foundation
import MLX
import MLXVLM
import XCTest
@testable import MLXLMCommon
@_spi(Benchmarking) @testable import ProviderCore

private actor MiMoHostOperationGate {
    private var entered = false
    private var open = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var parked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        let waiters = entryWaiters; entryWaiters = []
        for waiter in waiters { waiter.resume() }
        if open { return }
        await withCheckedContinuation { parked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        open = true
        let continuation = parked; parked = nil; continuation?.resume()
    }
}

private final class MiMoHostSynchronousGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    func holdOnce() {
        let first = lock.withLock { () -> Bool in
            guard !used else { return false }; used = true; return true
        }
        guard first else { return }
        entered.continuation.yield(); entered.continuation.finish()
        releaseSignal.wait()
    }
    func release() { releaseSignal.signal() }
    // No destructor wait: a one-shot signal is never consumed twice.
}

private final class MiMoHostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class MiMoHostWeakBundleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var bundle: ProviderEngineBundle?
    private weak var handle: ProviderMTPAssistantHandle?
    func record(_ bundle: ProviderEngineBundle, _ handle: ProviderMTPAssistantHandle) {
        lock.withLock { self.bundle = bundle; self.handle = handle }
    }
    var bundleAlive: Bool { lock.withLock { bundle != nil } }
    var assistant: ProviderMTPAssistantHandle? { lock.withLock { handle } }
}

/// Prepared only. Metadata cases use the real strict header/session/permit and
/// ledger with a declared coherent synthetic usage reader, but no native model,
/// allocation/eval, successful fake drain or materialized-M credit. Fixture setup
/// copies the existing bounded synthetic files; it creates no new weights.
final class MiMoV26NativeLoadTransactionTests: XCTestCase {
    private enum FixtureError: Error { case fixtureRequired, nativeLaneRequired }
    private let gib: UInt64 = 1 << 30

    private func allowMetadata() throws {
        if ProcessInfo.processInfo.environment["MIMO_V26_HOST_FAULT_CASE"] != nil {
            throw XCTSkip("Retained-fault selector runs alone in its own process")
        }
    }
    private func nativeLane(faultCase: String? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1" else { throw FixtureError.nativeLaneRequired }
        guard environment["MIMO_V26_HOST_FAULT_CASE"] == faultCase else {
            throw XCTSkip("Run the exact retained-fault selector alone")
        }
    }
    private func retainFaultUntilProcessExit(_ registry: MiMoV26NativeLoadRegistry) {
        if registry.hasRetainedFault { _ = Unmanaged.passRetained(registry) }
    }
    private func budget(native: Bool = false) -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 0.90, activationReserveBytes: 11 * gib / 2,
            configReserveBytes: 4 * gib, memorySnapshot: {
                if native {
                    let value = Memory.snapshot()
                    return .init(total: ProcessInfo.processInfo.physicalMemory,
                        active: UInt64(max(0, value.activeMemory)), cache: UInt64(max(0, value.cacheMemory)),
                        systemAvailable: .max)
                }
                return .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
            })
    }
    private func fixture() throws -> URL {
        guard let source = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw FixtureError.fixtureRequired
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-host-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        // Keep native/fault fixture evidence until the authorized test process
        // exits; no test removes a file backing retained native Load nodes.
        let config = try Data(contentsOf: root.appendingPathComponent("config.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let manifest: [String: Any] = [
            "source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL",
            "source_revision": String(repeating: "a", count: 40),
            "source_config_sha256": MiMoV26ServingLoad.hash(config),
            "experts": "original E2M1/E8M0 codes, group 32, no requantization",
            "dense": "FP8 dequantized to BF16; original BF16 unchanged",
            "output_tensor_count": weights.count,
            "output_weight_bytes": try XCTUnwrap(metadata["total_size"]),
            "modality_tensor_counts": Dictionary(uniqueKeysWithValues:
                ["visual", "audio_encoder", "speech_embeddings"].map { prefix in
                    (prefix, weights.keys.filter { $0.hasPrefix(prefix + ".") }.count)
                }),
            "mtp_embedded": ["architecture": "mimo_v2_nextn", "storage": "embedded",
                            "num_layers": 3, "file": "model-mtp.safetensors"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("conversion_manifest.json"))
        // Actual bounded BPE/Jinja, only synthetic control-flow evidence.
        let literal = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
        let vocab = ["<unk>": 0, "<|im_end|>": 1, "<|im_start|>": 9, "<think>": 10, "</think>": 11, "x": 12, "<stop>": 13]
        let added: [[String: Any]] = vocab.filter { $0.key != "x" }.map { token, id in
            ["id": id, "content": token, "single_word": false, "lstrip": false,
             "rstrip": false, "normalized": false, "special": true]
        }
        let tokenizer: [String: Any] = ["version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": added, "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"],
            "post_processor": NSNull(), "decoder": ["type": "ByteLevel"],
            "model": ["type": "BPE", "vocab": vocab, "merges": [], "unk_token": "<unk>",
                      "byte_fallback": false, "fuse_unk": false]]
        try JSONSerialization.data(withJSONObject: tokenizer, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("tokenizer.json"))
        try JSONSerialization.data(withJSONObject: ["tokenizer_class": "PreTrainedTokenizerFast",
            "eos_token": "<|im_end|>", "unk_token": "<unk>", "chat_template": literal])
            .write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data(literal.utf8).write(to: root.appendingPathComponent("chat_template.jinja"))
        try JSONSerialization.data(withJSONObject: ["eos_token_id": [1, 13]])
            .write(to: root.appendingPathComponent("generation_config.json"))
        return root
    }
    private func install(_ registry: MiMoV26NativeLoadRegistry, budget: GlobalKVCacheBudget)
        throws -> (MiMoV26ServingLoad, MiMoV26NativeLoadTransaction, MiMoV26NativeLifecycle) {
        let life = try registry.openLifecycle()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        try load.claim(budget: budget, lifecycle: life, registry: registry)
        return (load, try XCTUnwrap(load.transaction), life)
    }

    private static func buildBridge(load: MiMoV26ServingLoad, transaction: MiMoV26NativeLoadTransaction,
                                    container: ModelContainer, budget: GlobalKVCacheBudget) async throws -> EngineV2Bridge {
        // Refusal belongs OUTSIDE the owned-construction catch: a duplicate
        // assembly must not revoke the already constructed/published pipeline.
        try transaction.claimSlotAssembly(container)
        return try await transaction.performSetup {
            let engine = try await transaction.withNativeConstruction { model, scope in
                let binding = try model.makeCBv2Binding()
                _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
                let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                    backend: resources.backend, cacheProvider: resources.cacheProvider,
                    schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                    nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                try transaction.registerEngine(engine, executionContract: resources.contract)
                return engine
            }
            let info = try await container.perform { context in
                guard let model = context.model as? MiMoV26LoadedModel else { throw FixtureError.fixtureRequired }
                return (TokenizerHandle(context.tokenizer), model.stopTokenIDs)
            }
            try transaction.recheckSetup()
            let bridge = EngineV2Bridge(engine: engine, modelId: "synthetic-native-mimo",
                tokenizer: info.0, eosTokenIds: info.1, defaultMaxTokens: 4,
                maxConcurrentRequests: 1, prefillDeadlineProjectionEnabled: false,
                kvBudget: budget, advertisedContextTokens: load.plan.bundlePlan.configuration.maxPositionEmbeddings,
                emitTelemetry: { _ in })
            try transaction.registerBridge(bridge)
            try await bridge.attachNativeTransaction(transaction)
            try transaction.registerBundle(ProviderEngineBundle(targetOnly: bridge))
            return bridge
        }
    }

    private static func buildONBundle(load: MiMoV26ServingLoad, transaction: MiMoV26NativeLoadTransaction,
                                      container: ModelContainer, budget: GlobalKVCacheBudget,
                                      probe: MiMoHostWeakBundleProbe) async throws -> ProviderEngineBundle {
        try transaction.claimSlotAssembly(container)
        return try await transaction.performSetup {
            let native = try await transaction.withNativeConstruction { model, scope in
                let binding = try model.makeCBv2Binding(enableMTP: true)
                let assistant = ProviderMTPAssistantHandle(owner: model, drafter: try XCTUnwrap(binding.assistant))
                try transaction.registerAssistant(assistant)
                _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
                let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                    backend: resources.backend, cacheProvider: resources.cacheProvider,
                    schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                    mtpDrafter: binding.assistant,
                    mtpConfig: .init(enabled: true, maxDraftTokens: 3, maxSpeculativeBatch: 1,
                        fixedDraftTokens: 3, verificationMode: .serialTarget),
                    nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                try transaction.registerEngine(engine, executionContract: resources.contract)
                XCTAssertNil(engine.mtpInactiveReason)
                return (engine, assistant)
            }
            let info = await container.perform { context in
                (TokenizerHandle(context.tokenizer), (context.model as? MiMoV26LoadedModel)?.stopTokenIDs ?? [])
            }
            let bridge = EngineV2Bridge(engine: native.0, modelId: "synthetic-native-mimo-on",
                tokenizer: info.0, eosTokenIds: info.1, defaultMaxTokens: 4,
                maxConcurrentRequests: 1, prefillDeadlineProjectionEnabled: false,
                kvBudget: budget, advertisedContextTokens: load.plan.bundlePlan.configuration.maxPositionEmbeddings,
                emitTelemetry: { _ in })
            try transaction.registerBridge(bridge)
            try await bridge.attachNativeTransaction(transaction)
            let bundle = ProviderEngineBundle(bridge: bridge, assistant: native.1, assistantBytes: 0,
                mtpArtifact: nil, mtpStatus: .init(configured: true, active: true, reason: nil,
                    source: .inline, revision: nil, artifactBytes: 0, assistantBytes: 0))
            try transaction.registerBundle(bundle) // before return or ANY later veto
            probe.record(bundle, native.1)
            return bundle
        }
    }

    func testMetadataCancellationRetainsRealPermitUntilActualNoSubmissionReceipt() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let other = budget.processLedger.createOwner()
        let unchanged = try budget.processLedger.replaceCharge(owner: other.owner,
            expectedRevision: other.revision, expectedPolicyEpoch: budget.processLedger.policySnapshot().epoch,
            chargedBytes: 4096)
        let (load, transaction, _) = try install(registry, budget: budget)
        let before = budget.processLedger.snapshot().chargedBytes
        XCTAssertGreaterThan(before, 4096)
        load.revoke()
        XCTAssertFalse(registry.hasRetainedFault)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, before)
        XCTAssertEqual(transaction.snapshot().permit?.ownerState?.closing, true)
        let result = await load.finishFailureAfterUnwind()
        guard case .retired(let receipt) = result else { return XCTFail("metadata cancellation not retired") }
        XCTAssertEqual(receipt.transactionID, transaction.id)
        XCTAssertEqual(receipt.sessionID, load.request.sessionID)
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertNil(receipt.engine)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 4096)
        XCTAssertEqual(budget.processLedger.state(for: other.owner), unchanged)
        XCTAssertFalse(registry.retainedTransactionIDs.contains(transaction.id))
        guard case .retired(let again) = await transaction.retire() else { return XCTFail("not idempotent") }
        XCTAssertEqual(again.transactionID, receipt.transactionID)
        _ = budget.processLedger.retire(other.owner)
    }

    func testRegistryOwnsActualTransactionAfterFacadeAndCallerAliasesDisappear() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        var load: MiMoV26ServingLoad? = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        let life = try registry.openLifecycle()
        try load!.claim(budget: budget, lifecycle: life, registry: registry)
        weak var witness = load!.transaction
        let id = try XCTUnwrap(witness).id
        let charge = budget.processLedger.snapshot().chargedBytes
        load = nil
        XCTAssertNotNil(witness)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, charge)
        let owner = try XCTUnwrap(registry.transaction(id))
        guard case .retired(let receipt) = await owner.retire() else { return XCTFail("unstarted owner") }
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testHeldCancelledOperationRemainsPendingWithoutPoisoningProcess() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let (_, transaction, _) = try install(registry, budget: budget)
        let gate = MiMoHostOperationGate()
        let task = try registry.launchOwnedTask(for: transaction) {
            try await transaction.performSetup { await gate.hold() }
        }
        await gate.waitForEntry()
        let charge = budget.processLedger.snapshot().chargedBytes
        transaction.revoke()
        guard case .pending = await transaction.retire() else { return XCTFail("cancellation invented completion") }
        XCTAssertGreaterThan(transaction.snapshot().activeOperations, 0)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, charge)
        XCTAssertFalse(registry.hasRetainedFault)
        await gate.release()
        _ = await task.result
        await registry.joinOwnedTasksFromOutside(transaction)
        guard case .retired(let receipt) = await transaction.retire() else { return XCTFail("completed metadata task held forever") }
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(registry.hasRetainedFault)
    }

    func testLifecycleCloseRejectsOldGenerationAndReopenWaitsForRealRetirement() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let (_, transaction, life) = try install(registry, budget: budget)
        let closed = try registry.closeLifecycle(life)
        XCTAssertThrowsError(try registry.install(request: transaction.request, budget: budget, lifecycle: life))
        XCTAssertThrowsError(try registry.reopenLifecycle(closed)) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .pendingWork)
        }
        XCTAssertFalse(registry.hasRetainedFault)
        guard case .retired = await transaction.retire() else { return XCTFail("closed generation") }
        let next = try registry.reopenLifecycle(closed)
        XCTAssertGreaterThan(next.generation, life.generation)
        let nextLoad = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        try nextLoad.claim(budget: budget, lifecycle: next, registry: registry)
        guard case .retired = await nextLoad.finishFailureAfterUnwind() else { return XCTFail("next generation") }
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testForeignLifecycleAndNoSubmissionCannotAuthorizePublication() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), other = MiMoV26NativeLoadRegistry(), budget = budget()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        XCTAssertThrowsError(try load.claim(budget: budget, lifecycle: other.openLifecycle(), registry: registry))
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let transaction = try XCTUnwrap(load.transaction)
        var published = false
        XCTAssertThrowsError(try transaction.commitPublication { published = true })
        XCTAssertFalse(published)
        do { _ = try await load.sealConstructionForPublication(); XCTFail("metadata became serving proof") }
        catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .pendingWork) }
        XCTAssertNotEqual(transaction.snapshot().phase, .draining)
        guard case .retired = await load.finishFailureAfterUnwind() else { return XCTFail("metadata cleanup") }
    }

    func testNativeLoadedCancellationUsesRealScopeAndDropsRawContainerAfterCompletion() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        weak var witness = returned?.autoregressive
        XCTAssertNotNil(witness)
        let before = budget.processLedger.snapshot().chargedBytes
        XCTAssertGreaterThan(before, 0)
        load.revoke(); returned = nil
        XCTAssertNotNil(witness, "transaction must own the actual adopted container")
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("native cancellation cleanup") }
        XCTAssertEqual(receipt.construction.completion, .capturedStreamsCompleted)
        XCTAssertNil(receipt.engine)
        XCTAssertNil(witness)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(registry.hasRetainedFault)
        XCTAssertFalse(transaction.snapshot().hasContainer)
    }

    func testNativeActualEngineReceiptBindsContractAndRetiresWithoutBridge() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        var actual: EngineV2? = try await transaction.withNativeConstruction { model, scope in
            let binding = try model.makeCBv2Binding()
            _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
            let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
            let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                backend: resources.backend, cacheProvider: resources.cacheProvider,
                schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
            try transaction.registerEngine(engine, executionContract: resources.contract)
            return engine
        }
        let id = try XCTUnwrap(actual).nativeShutdownEngineID
        let contract = try XCTUnwrap(actual?.nativeShutdownExecutionContractID)
        actual = nil; returned = nil
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("real tracked engine did not retire") }
        XCTAssertEqual(receipt.engine?.engineID, id)
        XCTAssertEqual(receipt.engine?.executionContractID, contract)
        XCTAssertEqual(receipt.engine?.generation, 1)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(transaction.snapshot().hasEngine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testNativePublicationCommitsInsideGenerationGateAndWarmRebuildRefuses() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        var bridge: EngineV2Bridge? = try await Self.buildBridge(load: load, transaction: transaction,
            container: XCTUnwrap(returned?.autoregressive), budget: budget)
        let proof = try await load.sealConstructionForPublication()
        var inserted = false
        let publishedID = try load.commitPublication { inserted = true; return transaction.id }
        XCTAssertTrue(inserted); XCTAssertEqual(publishedID, transaction.id)
        XCTAssertEqual(transaction.snapshot().phase, .published)
        XCTAssertEqual(transaction.snapshot().permit?.lifecycle, .retired)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertNoThrow(try transaction.requireServingWorkAllowed())
        XCTAssertThrowsError(try load.recheck()) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .warmRebuildUnsupported)
        }
        XCTAssertThrowsError(try load.commitPublication { XCTFail("duplicate publication") })
        returned = nil; bridge = nil
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("published native lifetime did not drain") }
        XCTAssertEqual(receipt.construction, proof); XCTAssertNotNil(receipt.engine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testNativeStopAfterSealCannotPublishAndStillRetiresActualBridge() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, life) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        var bridge: EngineV2Bridge? = try await Self.buildBridge(load: load, transaction: transaction,
            container: XCTUnwrap(returned?.autoregressive), budget: budget)
        _ = try await load.sealConstructionForPublication()
        _ = try registry.closeLifecycle(life)
        var inserted = false
        XCTAssertThrowsError(try load.commitPublication { inserted = true }) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .lifecycleClosed)
        }
        XCTAssertFalse(inserted); XCTAssertFalse(registry.hasRetainedFault)
        XCTAssertGreaterThan(budget.processLedger.snapshot().chargedBytes, 0)
        returned = nil; bridge = nil
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("closed native generation did not drain") }
        XCTAssertNotNil(receipt.engine)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(registry.hasRetainedFault)
    }

    func testNativeForeignTransactionEngineCannotBeRegisteredOrDrained() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (loadA, a, _) = try install(registry, budget: budget)
        let (loadB, b, _) = try install(registry, budget: budget)
        var containerA: ProviderModelContainer? = try await loadA.load()
        var containerB: ProviderModelContainer? = try await loadB.load()
        let foreign = try await b.withNativeConstruction { model, scope in
            let binding = try model.makeCBv2Binding()
            _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
            let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
            let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                backend: resources.backend, cacheProvider: resources.cacheProvider,
                schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
            try b.registerEngine(engine, executionContract: resources.contract)
            return (engine, resources.contract)
        }
        let ownerB = try XCTUnwrap(b.snapshot().permit?.ownerState)
        do {
            try await a.withNativeConstruction { _, _ in
                try a.registerEngine(foreign.0, executionContract: foreign.1)
            }
            XCTFail("foreign work's actual engine/contract accepted")
        } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .foreignOwner) }
        XCTAssertFalse(a.snapshot().hasEngine); XCTAssertTrue(b.snapshot().hasEngine)
        containerA = nil
        guard case .retired(let receiptA) = await loadA.finishFailureAfterUnwind() else { return XCTFail("A failed to retire") }
        XCTAssertNil(receiptA.engine)
        XCTAssertEqual(budget.processLedger.state(for: ownerB.owner), ownerB)
        // Actual one-token native execution proves A did not shut down B.
        // This raw diagnostic does not assert bridge request-ledger parity.
        let events = try foreign.0.submit(.init(id: .init(9701), promptTokens: [9, 12],
            sampling: .init(temperature: 0), maxTokens: 1, prefixCacheEnabled: false))
        var tokens = 0
        for await event in events { if case .delta(_, let values, _) = event { tokens += values.count } }
        XCTAssertEqual(tokens, 1)
        containerB = nil
        guard case .retired(let receiptB) = await loadB.finishFailureAfterUnwind() else { return XCTFail("B failed to retire") }
        XCTAssertEqual(receiptB.engine?.engineID, foreign.0.nativeShutdownEngineID)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        withExtendedLifetime(containerA) {}; withExtendedLifetime(containerB) {}
    }

    func testNativeWatchdogRetainsActualOwnersAndRefusesNewProcessWork() async throws {
        try nativeLane(faultCase: "testNativeWatchdogRetainsActualOwnersAndRefusesNewProcessWork")
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        let returned = try await load.load()
        let actual = try await transaction.withNativeConstruction { model, scope in
            let binding = try model.makeCBv2Binding()
            _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
            let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
            let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                backend: resources.backend, cacheProvider: resources.cacheProvider,
                schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                loopConfig: .init(shutdownTimeout: 0.02),
                nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
            try transaction.registerEngine(engine, executionContract: resources.contract)
            return engine
        }
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocked = Task.detached {
            actual.loopForTesting.onEngineQueueSync {
                entered.continuation.yield()
                entered.continuation.finish()
                release.wait()
            }
        }
        for await _ in entered.stream { break }
        let charge = budget.processLedger.snapshot().chargedBytes
        let outcome = await transaction.retire()
        release.signal()
        await blocked.value
        guard case .retainedFault(let code) = outcome else { return XCTFail("watchdog minted success") }
        XCTAssertEqual(code, "engine_shutdownTimedOut")
        XCTAssertTrue(registry.hasRetainedFault)
        XCTAssertTrue(transaction.snapshot().hasEngine); XCTAssertTrue(transaction.snapshot().hasContainer)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, charge)
        XCTAssertThrowsError(try registry.requireNewNativeWorkAllowed())
        guard case .retainedFault = await transaction.retire() else { return XCTFail("late queue progress refunded fault") }
        withExtendedLifetime(returned) {}
    }

    func testHeldPermitReaderPreparationLeavesRegistryResponsiveAndRejectsLateClaim() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        let life = try registry.openLifecycle()
        let transaction = try registry.install(request: load.request, budget: budget, lifecycle: life)
        let gate = MiMoHostSynchronousGate()
        defer { gate.release() }
        transaction.setUsageReaderPreparationHookForTesting { gate.holdOnce() }
        let claim = Task.detached { try transaction.claimPermit() }
        for await _ in gate.entered.stream { break }
        XCTAssertEqual(transaction.snapshot().activeOperations, 1)
        XCTAssertNil(transaction.snapshot().permit)
        XCTAssertTrue(registry.retainedTransactionIDs.contains(transaction.id))
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        XCTAssertThrowsError(try transaction.claimPermit()) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .pendingWork)
        }
        let closed = try registry.closeLifecycle(life) // must not wait on the held preparation
        XCTAssertTrue(transaction.isCancellationRequested)
        XCTAssertTrue(registry.hasUnretiredClosingTransactions)
        guard case .pending(.activeOperations) = await transaction.retire() else {
            return XCTFail("live reader preparation was treated as completed metadata")
        }
        XCTAssertThrowsError(try registry.reopenLifecycle(closed))
        gate.release()
        do { try await claim.value; XCTFail("stale preparation installed a late permit") }
        catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .lifecycleClosed) }
        XCTAssertEqual(transaction.snapshot().activeOperations, 0)
        XCTAssertNil(transaction.snapshot().permit)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        guard case .retired(let receipt) = await transaction.retire() else { return XCTFail("unstarted claim failed to retire") }
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertFalse(registry.hasRetainedFault)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        _ = try registry.reopenLifecycle(closed)
    }

    func testClosingVisibilityIncludesRealRevokedPermitBeforeExplicitTransactionCancel() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let (_, transaction, _) = try install(registry, budget: budget)
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        let policy = budget.processLedger.policySnapshot()
        _ = budget.processLedger.updatePolicy(.init(epoch: policy.epoch + 1, capBytes: 0, reserveBytes: 0))
        XCTAssertThrowsError(try transaction.recheckSetup())
        XCTAssertEqual(transaction.snapshot().permit?.lifecycle, .revoked)
        XCTAssertFalse(transaction.isCancellationRequested, "permit refusal can precede host cancellation")
        XCTAssertTrue(registry.hasUnretiredClosingTransactions)
        XCTAssertGreaterThan(budget.processLedger.snapshot().chargedBytes, 0)
        guard case .retired = await transaction.retire() else { return XCTFail("revoked permit retirement") }
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        XCTAssertFalse(registry.hasRetainedFault)
    }

    func testProductionReaderUsesRealPreparationAndLedgerWithoutSyntheticOSHeadroom() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry()
        defer { retainFaultUntilProcessExit(registry) }
        // Public production initializer: actual allocator counters/OS headroom,
        // NOT the diagnostic memorySnapshot initializer with an empty prepare.
        let budget = GlobalKVCacheBudget(capFraction: 0.90, activationReserveBytes: 11 * gib / 2,
                                         configReserveBytes: 4 * gib)
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture()))
        let life = try registry.openLifecycle()
        let transaction = try registry.install(request: load.request, budget: budget, lifecycle: life)
        let observed = MiMoHostCounter()
        transaction.setUsageReaderPreparationHookForTesting {
            XCTAssertTrue(registry.retainedTransactionIDs.contains(transaction.id))
            XCTAssertEqual(transaction.snapshot().activeOperations, 1)
            observed.increment()
        }
        try transaction.claimPermit()
        XCTAssertEqual(observed.count, 1)
        let owner = try XCTUnwrap(transaction.snapshot().permit?.ownerState)
        XCTAssertGreaterThan(owner.chargedBytes, 0)
        XCTAssertEqual(owner.materializedBytes, 0)
        XCTAssertEqual(budget.processLedger.state(for: owner.owner), owner)
        guard case .retired(let receipt) = await transaction.retire() else { return XCTFail("production-reader metadata claim") }
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertNil(budget.processLedger.state(for: owner.owner))
        XCTAssertFalse(registry.hasRetainedFault)
    }

    func testConcurrentNativeConstructionCannotAdvanceRegisteredEngineEpoch() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        let gate = MiMoHostSynchronousGate(), secondBody = MiMoHostCounter()
        defer { gate.release() }
        let secondFinished = expectation(description: "overlapping native claim refused before SDK entry")
        let first = try registry.launchOwnedTask(for: transaction) {
            try await transaction.performSetup {
                try await transaction.withNativeConstruction { model, scope in
                    gate.holdOnce() // actual SDK work lock held; no second epoch may enter
                    let binding = try model.makeCBv2Binding()
                    _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    let resources = try binding.adapter.makeNativeExecutionResources(bytesCapacity: 16 << 20, retaining: scope)
                    let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                        backend: resources.backend, cacheProvider: resources.cacheProvider,
                        schedulerConfig: .init(maxConcurrentRequests: 1, enablePrefixCache: false),
                        nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                    try transaction.registerEngine(engine, executionContract: resources.contract)
                    return engine
                }
            }
        }
        for await _ in gate.entered.stream { break }
        let heldEpoch = transaction.snapshot().constructionEpoch
        let second = try registry.launchOwnedTask(for: transaction) {
                do {
                    try await transaction.withNativeConstruction { _, _ in secondBody.increment() }
                    XCTFail("overlapping native scope accepted")
                } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .pendingWork) }
                secondFinished.fulfill()
        }
        // Escape timeout only; the exact body counter + unchanged epoch below
        // are causal oracles. Release first even if the refusal test timed out.
        await fulfillment(of: [secondFinished], timeout: 10)
        XCTAssertEqual(transaction.snapshot().constructionEpoch, heldEpoch)
        XCTAssertFalse(transaction.isCancellationRequested)
        gate.release()
        var actual: EngineV2? = try await first.value
        _ = try await second.value
        XCTAssertEqual(secondBody.count, 0)
        XCTAssertEqual(try transaction.currentConstructionReceipt().epoch, heldEpoch)
        await registry.joinOwnedTasksFromOutside(transaction)
        let epoch = try transaction.currentConstructionReceipt().epoch
        do {
            try await transaction.withNativeConstruction { _, _ in secondBody.increment() }
            XCTFail("registered engine reopened native setup")
        } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .warmRebuildUnsupported) }
        XCTAssertEqual(secondBody.count, 0)
        XCTAssertEqual(try transaction.currentConstructionReceipt().epoch, epoch)
        XCTAssertFalse(transaction.isCancellationRequested)
        let events = try XCTUnwrap(actual).submit(.init(id: .init(9801), promptTokens: [9, 12],
            sampling: .init(temperature: 0), maxTokens: 1, prefixCacheEnabled: false))
        var tokens = 0
        for await event in events { if case .delta(_, let values, _) = event { tokens += values.count } }
        XCTAssertEqual(tokens, 1, "refused duplicate must not poison the original actual engine")
        actual = nil; returned = nil
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("exclusive native scope cleanup") }
        XCTAssertEqual(receipt.construction.epoch, epoch)
        XCTAssertNotNil(receipt.engine)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        withExtendedLifetime(returned) {}
    }

    func testAssemblyAndBridgeIdentityClaimsDoNotCancelExistingPipeline() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (loadA, a, _) = try install(registry, budget: budget)
        let (loadB, b, _) = try install(registry, budget: budget)
        var returnedA: ProviderModelContainer? = try await loadA.load()
        var returnedB: ProviderModelContainer? = try await loadB.load()
        var containerA: ModelContainer? = try XCTUnwrap(returnedA?.autoregressive)
        var containerB: ModelContainer? = try XCTUnwrap(returnedB?.autoregressive)
        XCTAssertNoThrow(try a.validateContainerIdentity(XCTUnwrap(containerA)))
        XCTAssertThrowsError(try a.validateContainerIdentity(XCTUnwrap(containerB))) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .foreignOwner)
        }
        XCTAssertThrowsError(try a.claimSlotAssembly(XCTUnwrap(containerB)))
        XCTAssertFalse(a.isCancellationRequested); XCTAssertFalse(b.isCancellationRequested)
        var bridgeA: EngineV2Bridge? = try await Self.buildBridge(load: loadA, transaction: a,
            container: XCTUnwrap(containerA), budget: budget)
        var bridgeB: EngineV2Bridge? = try await Self.buildBridge(load: loadB, transaction: b,
            container: XCTUnwrap(containerB), budget: budget)
        let candidateA = try XCTUnwrap(bridgeA), candidateB = try XCTUnwrap(bridgeB)
        try await a.performSetup {
            XCTAssertNoThrow(try a.validateRegisteredBridge(candidateA))
            XCTAssertThrowsError(try a.validateRegisteredBridge(candidateB)) {
                XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .foreignOwner)
            }
        }
        XCTAssertThrowsError(try a.claimSlotAssembly(XCTUnwrap(containerA))) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .slotAssemblyAlreadyClaimed)
        }
        let sameContainer = try XCTUnwrap(containerA)
        do {
            try await a.performSetup { try a.claimSlotAssembly(sameContainer) }
            XCTFail("outer setup accepted duplicate assembly")
        } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .slotAssemblyAlreadyClaimed) }
        XCTAssertFalse(a.isCancellationRequested)
        XCTAssertTrue(a.snapshot().hasEngine); XCTAssertTrue(a.snapshot().hasBridge)
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        _ = try await loadA.sealConstructionForPublication()
        _ = try loadA.commitPublication { a.id }
        XCTAssertThrowsError(try a.claimSlotAssembly(XCTUnwrap(containerA))) {
            XCTAssertEqual($0 as? MiMoV26NativeTransactionError, .warmRebuildUnsupported)
        }
        XCTAssertNoThrow(try a.requireServingWorkAllowed())
        XCTAssertFalse(a.isCancellationRequested)
        XCTAssertFalse(registry.hasUnretiredClosingTransactions)
        XCTAssertTrue(b.snapshot().hasEngine); XCTAssertFalse(b.isCancellationRequested)
        bridgeA = nil; bridgeB = nil; containerA = nil; containerB = nil
        returnedA = nil; returnedB = nil
        guard case .retired = await loadA.finishFailureAfterUnwind() else { return XCTFail("A assembly cleanup") }
        guard case .retired = await loadB.finishFailureAfterUnwind() else { return XCTFail("B assembly cleanup") }
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        // candidateA/B are known passive actor handles; no physical-free claim.
        withExtendedLifetime(candidateA) {}; withExtendedLifetime(candidateB) {}
    }

    func testActualONBundleSurvivesOuterVetoUntilTypedRetirement() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        let raw = try XCTUnwrap(returned?.autoregressive)
        let probe = MiMoHostWeakBundleProbe(), gate = MiMoHostOperationGate()
        let construction = try registry.launchOwnedTask(for: transaction) {
            try await transaction.performSetup { () async throws -> Void in
                let bundle = try await Self.buildONBundle(load: load, transaction: transaction,
                    container: raw, budget: budget, probe: probe)
                await gate.hold()
                // Caller cancellation arrives after factory return. Its final
                // recheck rejects, and this local real bundle then disappears.
                withExtendedLifetime(bundle) {}
            }
        }
        await gate.waitForEntry()
        let charge = budget.processLedger.snapshot().chargedBytes
        transaction.revoke()
        guard case .pending = await transaction.retire() else { return XCTFail("live outer setup retired") }
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(probe.bundleAlive)
        XCTAssertNotNil(probe.assistant?.drafter)
        XCTAssertNotNil(transaction.registeredBridgeForRetirement())
        await gate.release()
        do { try await construction.value; XCTFail("cancelled outer setup published its bundle") } catch {}
        await registry.joinOwnedTasksFromOutside(transaction)
        returned = nil
        let handle = try XCTUnwrap(probe.assistant)
        XCTAssertTrue(probe.bundleAlive, "TX must hold the actual bundle, not only its releasable handle")
        XCTAssertNotNil(handle.drafter, "outer unwind must not trigger bundle.deinit assistant release")
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, charge)
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else { return XCTFail("actual bundle retirement") }
        XCTAssertNotNil(receipt.engine)
        XCTAssertFalse(transaction.snapshot().hasBundle)
        XCTAssertFalse(probe.bundleAlive)
        XCTAssertNil(handle.drafter)
        XCTAssertNil(transaction.registeredBridgeForRetirement())
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        // raw is a known passive caller alias: this is NOT physical-free credit.
        withExtendedLifetime(raw) {}; withExtendedLifetime(returned) {}
    }
    func testLateCancelledPrefixPreparationRetainsActualStoreUntilOwnedUnwind() async throws {
        try allowMetadata()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget()
        let (load, transaction, _) = try install(registry, budget: budget)
        let layout = CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout
        let store = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: layout)
        let owner = MiMoV26NativePrefixResources(transactionID: transaction.id,
            sessionID: load.request.sessionID, budget: budget, identity: store.identity, backendLayout: layout)
        let gate = MiMoHostOperationGate()
        let preparation = Task {
            try await transaction.performSetup {
                try transaction.registerNativeCompletePrefixResources(owner)
                await gate.hold() // owned async store-return boundary
                try owner.install(store) // must capture even after cancellation
            }
        }
        await gate.waitForEntry()
        transaction.revoke()
        guard case .pending(.activeOperations) = await transaction.retire() else {
            await gate.release(); _ = await preparation.result
            return XCTFail("prefix preparation refunded while its actual result was outstanding")
        }
        XCTAssertNotNil(owner.processOwner.snapshot())
        await gate.release()
        do { try await preparation.value; XCTFail("late cancellation published") } catch {}
        XCTAssertTrue(owner.store === store)
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else {
            return XCTFail("real no-submission cleanup did not retire")
        }
        XCTAssertNil(receipt.engine)
        XCTAssertTrue(owner.snapshot().closeJoined)
        XCTAssertTrue(store.isClosed)
        XCTAssertNil(owner.processOwner.snapshot())
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        try FileManager.default.removeItem(at: store.config.dedicatedRoot)
    }

    func testNativeCompletePrefixOFFUsesExactOwnerAndRealRetirement() async throws {
        try await nativeCompletePrefixOwner(mtp: false)
    }

    func testNativeCompletePrefixONUsesExactOwnerAndRealRetirement() async throws {
        // Keep the default 512-token prefill chunk and 2048-token MTP work envelope.
        // That envelope exceeds this fixture's old 16 MiB local arena.
        // Fund this positive fixture; the underfunded case remains explicit below.
        try await nativeCompletePrefixOwner(mtp: true, bytesCapacity: 64 << 20)
    }

    func testNativeCompletePrefixONRefusesUnderfundedArenaAndRetiresCleanly() async throws {
        try await nativeCompletePrefixOwner(mtp: true, expectCapacityRefusal: true)
    }

    func testNativeCompletePrefixONPublishesAnActualInteriorBoundaryBeforeRetirement() async throws {
        try await nativeCompletePrefixOwner(mtp: true, requireInteriorPublication: true)
    }

    /// Real strict-loaded tiny target and actual optional assistant; constant
    /// fixture identity is NOT production artifact/prompt qualification.
    private func nativeCompletePrefixOwner(mtp: Bool, requireInteriorPublication: Bool = false,
                                          bytesCapacity: Int = 16 << 20,
                                          expectCapacityRefusal: Bool = false) async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        let raw = try XCTUnwrap(returned?.autoregressive)
        try transaction.claimSlotAssembly(raw)
        let (bundle, actual, owner) = try await transaction.performSetup {
            let metadata = try await transaction.withNativeConstruction { model, scope in
                let binding = try model.makeCBv2Binding(enableMTP: mtp)
                _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                return try model.nativeCompletePrefixMetadata(binding: binding, retaining: scope)
            }
            let owner = MiMoV26NativePrefixResources(transactionID: transaction.id,
                sessionID: load.request.sessionID, budget: budget,
                identity: MiMoPrefixStoreTestSupport.identity, backendLayout: metadata.backendLayout)
            try transaction.registerNativeCompletePrefixResources(owner)
            let store = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: metadata.backendLayout)
            try owner.install(store)
            let assembled = try await transaction.withNativeConstruction { model, scope in
                let binding = try model.makeCBv2Binding(enableMTP: mtp)
                _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                let handle = binding.assistant.map { ProviderMTPAssistantHandle(owner: $0, drafter: $0) }
                if let handle {
                    handle.bind(sourceTarget: model, servingTarget: model)
                    try transaction.registerAssistant(handle)
                }
                let resources = try model.makeNativeCompletePrefixExecutionResources(binding: binding,
                    bytesCapacity: bytesCapacity, expectedMetadata: metadata, completePrefixCache: store,
                    processMemoryOwner: owner.processOwner, retaining: scope)
                let geometry = try MiMoV26AdmissionGeometry(layerKinds: metadata.layerKinds,
                    probedDTypes: metadata.layerDTypes, maximumContextTokens: metadata.maximumContextTokens)
                var scheduler = CBv2SchedulerConfig(maxConcurrentRequests: 1, enablePrefixCache: true)
                if requireInteriorPublication {
                    // TEST ONLY: two128-token launches reach the store's real
                    // interior256 boundary in the existing257-token fixture.
                    // Production's512 default and prior test bodies stay intact.
                    scheduler.prefillChunkSize = 128
                    scheduler.maxBatchedTokensPerStep = 128
                }
                let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                    backend: resources.backend, cacheProvider: resources.cacheProvider,
                    schedulerConfig: scheduler,
                    admissionConfig: geometry.internalAdmissionConfig, completePrefixCache: store,
                    mtpDrafter: binding.assistant, mtpConfig: .init(enabled: mtp,
                        maxDraftTokens: 3, maxSpeculativeBatch: 1, verificationMode: .serialTarget),
                    processMemoryOwner: owner.processOwner,
                    nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                if mtp {
                    guard case .bounded(let envelope)? = engine.resolvedMTPAdmission else {
                        throw FixtureError.fixtureRequired
                    }
                    XCTAssertEqual(envelope.limits.maximumPrefillTokens,
                        requireInteriorPublication ? 128 : 2048)
                    XCTAssertEqual(engine.resolvedFixedBytesPerRequest, envelope.fixedBytesPerRequest,
                        "the assistant work envelope must be charged exactly once")
                    XCTAssertEqual(engine.admissionForTesting.auxiliaryBytesPerToken, 0,
                        "bounded MTP replaces the legacy per-token assistant charge")
                }
                XCTAssertEqual(engine.admissionForTesting.allocatedBytes(forTokens: 265),
                    try geometry.logicalTargetBytes(positiveTokens: 265) + engine.resolvedFixedBytesPerRequest,
                    "one target KV/ring charge plus one assistant envelope")
                try transaction.registerEngine(engine, executionContract: resources.contract)
                return (engine, handle, geometry.fullKVBytesPerToken,
                        try geometry.sharedFixedRequestBytes(resolvedNonTargetFixedBytes: engine.resolvedFixedBytesPerRequest))
            }
            let tokenizer = await raw.perform { TokenizerHandle($0.tokenizer) }
            let bridge = try EngineV2Factory.makeBridge(modelId: "synthetic-native-mimo-prefix",
                tokenizer: tokenizer, eosTokenIds: [], defaultMaxTokens: 8, maxConcurrentRequests: 1,
                kvBytesPerToken: assembled.2, kvBudget: budget, ssdHybridCheckpointStore: store) {
                .init(engine: assembled.0, fixedRequestBytes: assembled.3, kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil, mtpAdmissionResolution: assembled.0.resolvedMTPAdmission)
            }
            try transaction.registerBridge(bridge)
            try await bridge.attachNativeTransaction(transaction)
            let bundle = ProviderEngineBundle(bridge: bridge, assistant: assembled.1,
                assistantBytes: 0, mtpArtifact: nil,
                mtpStatus: .init(configured: mtp, active: mtp, reason: nil, source: mtp ? .inline : nil,
                    revision: nil, artifactBytes: 0, assistantBytes: 0))
            try transaction.registerBundle(bundle)
            return (bundle, assembled.0, owner)
        }
        XCTAssertTrue(actual.completePrefixCache === owner.store)
        XCTAssertTrue(actual.usesProcessMemoryOwner)
        XCTAssertTrue(actual.usesProcessMemoryOwner(owner.processOwner))
        let foreignProcessOwner = budget.makeEngineMemoryOwner()
        XCTAssertFalse(actual.usesProcessMemoryOwner(foreignProcessOwner),
            "even a real different owner from the same budget is not this Admission owner")
        foreignProcessOwner.retire() // never installed, zero C/M, no native work
        XCTAssertNil(foreignProcessOwner.snapshot())
        XCTAssertFalse(transaction.ownsNativeCompletePrefixRequestCharge(
            engine: actual, bridge: bundle.bridge, budget: budget), "unpublished is not charge authority")
        _ = try await load.sealConstructionForPublication()
        _ = try load.commitPublication { transaction.id }
        XCTAssertTrue(transaction.ownsNativeCompletePrefixRequestCharge(engine: actual, bridge: bundle.bridge, budget: budget))
        XCTAssertFalse(transaction.ownsNativeCompletePrefixRequestCharge(
            engine: actual, bridge: bundle.bridge, budget: MiMoPrefixStoreTestSupport.budget()))
        let foreignRegistry = MiMoV26NativeLoadRegistry()
        let (foreignLoad, foreign, _) = try install(foreignRegistry, budget: budget)
        // A missing/foreign actual owner cannot borrow this engine's marker.
        XCTAssertFalse(foreign.ownsNativeCompletePrefixRequestCharge(engine: actual, bridge: bundle.bridge, budget: budget))
        guard case .retired = await foreignLoad.finishFailureAfterUnwind() else {
            return XCTFail("foreign no-submission owner did not actually retire")
        }

        let requestID = "mimo-prefix-owned-request"
        let quote = actual.admissionForTesting.allocatedBytes(forTokens: 265)
        let available = actual.admissionForTesting.admissibleBytesCapacity
        print("MiMoPrefixQuote mtp=\(mtp) interior=\(requireInteriorPublication) arena=\(bytesCapacity) fixed=\(actual.resolvedFixedBytesPerRequest) needed=\(quote) available=\(available)")
        if expectCapacityRefusal {
            XCTAssertGreaterThan(quote, available)
        } else {
            XCTAssertLessThanOrEqual(quote, available)
        }
        let stepsBefore = actual.stepCount
        let chargeBefore = owner.processOwner.snapshot()
        let events = await bundle.bridge.submitTokenized(promptTokens: Array(repeating: 12, count: 257),
            request: .init(model: "synthetic-native-mimo-prefix", messages: [], temperature: 0, max_tokens: 8),
            requestId: requestID, cacheScope: "synthetic-owner-tenant")
        var terminals = 0, capacityRefusals = 0
        for await event in events {
            let ids = await budget.reservationIDsForTesting()
            XCTAssertFalse(ids.contains(requestID), "bridge duplicated the exact native Admission request owner")
            switch event {
            case .error(let error):
                if expectCapacityRefusal {
                    XCTAssertEqual(error, "token_budget_exhausted: request requires \(quote) tokens but only \(available) available")
                    capacityRefusals += 1
                } else { XCTFail(error) }
            case .terminal: XCTFail("unexpected native failure")
            case .info(_, let count, _, _): XCTAssertGreaterThan(count, 0); terminals += 1
            default: break
            }
        }
        if expectCapacityRefusal {
            XCTAssertEqual(capacityRefusals, 1)
            XCTAssertEqual(terminals, 0)
            XCTAssertEqual(actual.stepCount, stepsBefore, "unfunded request must not execute native work")
            XCTAssertEqual(actual.admissionForTesting.bytesReserved, 0)
            XCTAssertEqual(owner.processOwner.snapshot(), chargeBefore)
            let ids = await budget.reservationIDsForTesting()
            XCTAssertFalse(ids.contains(requestID))
        } else {
            XCTAssertEqual(capacityRefusals, 0)
            XCTAssertEqual(terminals, 1)
        }
        if requireInteriorPublication {
            // The stream's token terminal alone is not publication completion.
            // Join the actual pump/transferred retirement tasks BEFORE shutdown
            // can close the store and turn an intended write into a cold drop.
            // Do not join lifetime telemetry/posture monitors before shutdown.
            let pumps = await bundle.bridge.pumpTasks
            for task in pumps.values { await task.value }
            let transferred = await bundle.bridge.nativeTransferredRetirementTasks
            for task in transferred.values { await task.value }
            let store = try XCTUnwrap(owner.store)
            await store.waitForWritesForTesting()
            XCTAssertEqual(store.config.backendLayout,
                CBv2CompleteCheckpointManifest.contiguousAsymmetricMTPLayout)
            XCTAssertGreaterThan(store.stats().filesWritten, 0,
                "fresh engine-owned assistant context must reach real interior complete publication")
            XCTAssertEqual(store.stats().writesDropped, 0)
        }
        let contract = try XCTUnwrap(actual.nativeShutdownExecutionContractID)
        do { _ = try await bundle.bridge.shutdownNativeConstruction(expectedEngine: actual, executionContractID: contract) }
        catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            let snapshot = await bundle.bridge.nativeRetirementTaskSnapshot()
            XCTAssertEqual(snapshot.sdkQuiescence?.executionContractID, contract)
            for task in snapshot.tasks { await task.value }
        }
        returned = nil
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else {
            return XCTFail("genuine prefix native/bridge retirement unavailable")
        }
        XCTAssertEqual(receipt.engine?.engineID, actual.nativeShutdownEngineID)
        XCTAssertEqual(receipt.engine?.executionContractID, contract)
        XCTAssertTrue(owner.snapshot().bound); XCTAssertTrue(owner.snapshot().closeJoined)
        XCTAssertTrue(owner.snapshot().ownerRetired); XCTAssertNil(owner.processOwner.snapshot())
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        let store = try XCTUnwrap(owner.store)
        XCTAssertTrue(store.isClosed)
        try FileManager.default.removeItem(at: store.config.dedicatedRoot)
        // Passive local handles are not a claim about allocator/physical free.
        withExtendedLifetime(raw) {}; withExtendedLifetime(actual) {}; withExtendedLifetime(bundle) {}
    }

    func testNativeShutdownActivitySurvivesPendingHostUntilRealQuiescentDrain() async throws {
        try nativeLane()
        let registry = MiMoV26NativeLoadRegistry(), budget = budget(native: true)
        defer { retainFaultUntilProcessExit(registry) }
        let (load, transaction, _) = try install(registry, budget: budget)
        var returned: ProviderModelContainer? = try await load.load()
        let bridge = try await Self.buildBridge(load: load, transaction: transaction,
            container: XCTUnwrap(returned?.autoregressive), budget: budget)
        let actualValue = await bridge.ownedEngine as? EngineV2
        let actual = try XCTUnwrap(actualValue)
        let contract = try XCTUnwrap(actual.nativeShutdownExecutionContractID)
        _ = try await load.sealConstructionForPublication()
        _ = try load.commitPublication { transaction.id }
        let service = budget.serviceBudget
        XCTAssertTrue(service.deadlineWork(modelID: "synthetic-native-mimo", epoch: "test").known)
        let initialActivity = await bridge.nativeShutdownActivity
        XCTAssertNil(initialActivity)
        let entered = expectation(description: "actual bridge submission is suspended before native admission")
        let gate = MiMoHostOperationGate()
        await bridge._testInstallPreSubmitGate { entered.fulfill(); await gate.hold() }
        let submission = Task {
            await bridge.submitTokenized(promptTokens: [9, 12],
                request: .init(model: "synthetic-native-mimo", messages: [], temperature: 0, max_tokens: 1),
                requestId: "held-native-shutdown")
        }
        await fulfillment(of: [entered], timeout: 10)
        let pendingCount = await bridge._testPendingSubmissionCount()
        XCTAssertEqual(pendingCount, 1)
        do {
            _ = try await bridge.shutdownNativeConstruction(expectedEngine: actual, executionContractID: contract)
            XCTFail("suspended host submission cannot mint bridge completion")
        } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            // Actual SDK quiescence is insufficient while this host caller is parked.
        } catch {
            XCTFail("unexpected shutdown error: \(error)")
        }
        let pending = await bridge.nativeRetirementTaskSnapshot()
        XCTAssertEqual(pending.sdkQuiescence?.engineID, actual.nativeShutdownEngineID)
        XCTAssertEqual(pending.sdkQuiescence?.executionContractID, contract)
        let heldActivity = await bridge.nativeShutdownActivity
        XCTAssertNotNil(heldActivity)
        XCTAssertFalse(service.deadlineWork(modelID: "synthetic-native-mimo", epoch: "test").known)
        await gate.release()
        let events = await submission.value
        var errors = 0
        for await event in events {
            if case .error = event { errors += 1 }
            if case .info = event { XCTFail("closed pending submission executed") }
        }
        XCTAssertEqual(errors, 1)
        let remaining = await bridge._testPendingSubmissionCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(service.count, 0, "the actual request allowance has unwound")
        let afterHostUnwind = await bridge.nativeShutdownActivity
        XCTAssertTrue(heldActivity === afterHostUnwind)
        XCTAssertFalse(service.deadlineWork(modelID: "synthetic-native-mimo", epoch: "test").known,
            "host unwind alone must retain the independent native shutdown activity")
        let outcome = try await bridge.shutdownNativeConstruction(expectedEngine: actual, executionContractID: contract)
        guard case .quiescent(let receipt) = outcome else { return XCTFail("real SDK and host drain did not complete") }
        XCTAssertEqual(receipt.engineID, actual.nativeShutdownEngineID)
        XCTAssertEqual(receipt.executionContractID, contract)
        let drainedActivity = await bridge.nativeShutdownActivity
        XCTAssertNil(drainedActivity)
        XCTAssertTrue(service.deadlineWork(modelID: "synthetic-native-mimo", epoch: "test").known)
        returned = nil
        guard case .retired = await load.finishFailureAfterUnwind() else { return XCTFail("actual native owner failed to retire") }
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

}

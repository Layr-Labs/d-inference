import Foundation
import Dispatch
@testable import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import XCTest
@_spi(Benchmarking) @testable import ProviderCore

private actor NativeStandaloneGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var open = false
    let entered = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    func hold() async {
        entered.continuation.yield(); entered.continuation.finish()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if open { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { cancelled.continuation.yield(); cancelled.continuation.finish() }
    }
    func release() {
        open = true
        let previous = waiter; waiter = nil; previous?.resume()
    }
    nonisolated func taskEnded() {
        entered.continuation.finish(); cancelled.continuation.finish()
    }
    func waitForEntry() async { for await _ in entered.stream { return } }
    func waitForCancellation() async { for await _ in cancelled.stream { return } }
}

private final class NativeServiceQueueHold: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let released = DispatchSemaphore(value: 0)
    func hold() {
        entered.continuation.yield(); entered.continuation.finish()
        released.wait()
    }
    func release() { released.signal() }
}

private final class NativeServiceExitWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var joins = 0
    func finishInsideActualServiceTail() { lock.withLock { finished = true } }
    func observeActualJoin() -> Bool {
        lock.withLock { joins += 1; return finished }
    }
    var observedJoins: Int { lock.withLock { joins } }
}

private final class NativeStandaloneWitness: @unchecked Sendable {
    private let lock = NSLock()
    private weak var bundle: ProviderEngineBundle?
    private weak var model: AnyObject?
    private var storedTransaction: MiMoV26NativeLoadTransaction?
    private var clears = 0
    func watch(bundle: ProviderEngineBundle) { lock.withLock { self.bundle = bundle } }
    func watch(model: AnyObject) { lock.withLock { self.model = model } }
    func watch(transaction: MiMoV26NativeLoadTransaction) { lock.withLock { storedTransaction = transaction } }
    func cleared() { lock.withLock { clears += 1 } }
    var clearCount: Int { lock.withLock { clears } }
    var bundleAlive: Bool { lock.withLock { bundle != nil } }
    var modelAlive: Bool { lock.withLock { model != nil } }
    var transaction: MiMoV26NativeLoadTransaction? { lock.withLock { storedTransaction } }
    func dropTransaction() { lock.withLock { storedTransaction = nil } }
}

private struct NativeStandaloneView: Sendable {
    let loading, resident, stopped, stopping, hasBundle: Bool
    let setupActive, controlActive: Bool
    let consumers, reservations: Int
    let phases: [NativeLocalConsumerLease.Phase]
    let charge: UInt64
    let transactionID: UUID?
    let transactionPhase: MiMoV26NativeLoadTransaction.Phase?
    let mtp: Bool
}

private extension StandaloneServer {
    func nativeBridgeForServiceJoinTest(_ modelID: String) -> EngineV2Bridge? {
        nativeMiMoLoads[modelID]?.transaction?.registeredBridgeForRetirement()
    }

    func nativeRetirementForServiceJoinTest(_ modelID: String) -> MiMoV26NativeRetirement? {
        nativeMiMoLoads[modelID]?.retirement
    }

    func retryNativeAfterActualServiceProgressForTesting(_ modelID: String) async {
        guard let state = nativeMiMoLoads[modelID] else { return }
        // No asserted completion: compare the actual changed SDK/owner snapshot.
        await retireNativeMiMoIfReady(modelID: modelID,
            expectedLoad: state.load, afterActualProgress: false)
    }

    func nativeView(_ modelID: String) -> NativeStandaloneView {
        let state = nativeMiMoLoads[modelID]
        let transaction = state?.transaction?.snapshot()
        return .init(loading: modelsLoading.contains(modelID), resident: slots[modelID] != nil,
            stopped: lifecycleState == .stopped, stopping: lifecycleState == .stopping,
            hasBundle: transaction?.hasBundle ?? false,
            setupActive: state?.setupTask != nil, controlActive: state?.controlTask != nil,
            consumers: state?.consumers.count ?? 0, reservations: slotReservations[modelID] ?? 0,
            phases: state?.consumers.values.map { $0.snapshot().phase } ?? [],
            charge: kvBudget.processLedger.snapshot().chargedBytes,
            transactionID: transaction?.id, transactionPhase: transaction?.phase,
            mtp: slots[modelID]?.bundle.mtpStatus.active ?? false)
    }

    func watchNative(_ modelID: String, witness: NativeStandaloneWitness) async {
        guard let state = nativeMiMoLoads[modelID] else { return }
        if let transaction = state.transaction { witness.watch(transaction: transaction) }
        if let selected = state.candidate ?? slots[modelID] {
            witness.watch(bundle: selected.bundle)
            if let container = selected.container {
                await container.perform { context in
                    witness.watch(model: context.model)
                }
            }
        }
    }

    func nativeStepCount(_ modelID: String) async -> Int {
        guard let bridge = nativeMiMoLoads[modelID]?.transaction?.registeredBridgeForRetirement(),
              let engine = await bridge.ownedEngine as? EngineV2 else { return 0 }
        return engine.stepCount
    }

    func hasRetainedNativeOwner() -> Bool {
        !nativeMiMoLoads.isEmpty || nativeMiMoRegistry.hasRetainedFault
            || !nativeMiMoRegistry.retainedTransactionIDs.isEmpty
    }
}

/// New caller tests only, PREPARED/UNRUN. These explicitly bypass disabled
/// advertisement ONLY for a unique synthetic identity/path. They do not activate
/// the family or replace the strict loader, actual engine, real memory policy,
/// scheduler, lease joins, SDK outcomes or transaction retirement.
final class MiMoV26StandaloneLifecycleTests: XCTestCase {
    private enum FixtureError: Error { case payloadFixtureRequired, veto, unexpectedOwner, debugSeamsRequired }
    private let literal = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
    private var retainedServers: [StandaloneServer] = []

    override func tearDown() async throws {
        for server in retainedServers {
            guard await server.hasRetainedNativeOwner() else { continue }
            // A failed assertion must not destroy an unknown native owner.
            // Stop the native matrix in this process and preserve it to exit.
            _ = Unmanaged.passRetained(server)
        }
        retainedServers = []
        try await super.tearDown()
    }

    private func lane() throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS")
    }

    private func fixture() throws -> URL {
        guard let source = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw FixtureError.payloadFixtureRequired
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-serving-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        // Preserve bounded synthetic payloads until the owned test process
        // exits. A failing native gate can retain lazy Load roots, so generic
        // XCTest teardown must not unlink their backing files.
        let configURL = root.appendingPathComponent("config.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: configURL)) as? [String: Any])
        let vision = try XCTUnwrap(fields["vision_config"] as? [String: Any])
        var processor = try XCTUnwrap(fields["processor_config"] as? [String: Any])
        // The source tensors have a tiny tower, not the inherited full-size
        // processor. Retain the ordinary media profile with matching metadata.
        for (key, towerKey) in [("patch_size", "patch_size"),
                                ("merge_size", "spatial_merge_size"),
                                ("temporal_patch_size", "temporal_patch_size")] {
            processor[key] = try XCTUnwrap(vision[towerKey] as? Int)
        }
        processor["video_start_token_id"] = 14; processor["video_end_token_id"] = 15
        fields["processor_config"] = processor
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: configURL)
        let config = try Data(contentsOf: configURL)
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
        // Actual BPE implementation, finite vocab within the tiny model's128 IDs.
        let vocab = ["<unk>": 0, "<|im_end|>": 1, "<|image_pad|>": 2, "<|video_pad|>": 3,
            "<|vision_start|>": 4, "<|vision_end|>": 5, "<|audio_pad|>": 6,
            "<|mimo_audio_start|>": 7, "<|mimo_audio_end|>": 8,
            "<|im_start|>": 9, "<think>": 10, "</think>": 11, "x": 12, "<stop>": 13,
            "<|mimo_video_start|>": 14, "<|mimo_video_end|>": 15]
        for (key, spelling) in ["image_token_id": "<|image_pad|>", "video_token_id": "<|video_pad|>",
            "vision_start_token_id": "<|vision_start|>", "vision_end_token_id": "<|vision_end|>",
            "audio_token_id": "<|audio_pad|>", "audio_start_token_id": "<|mimo_audio_start|>",
            "audio_end_token_id": "<|mimo_audio_end|>", "video_start_token_id": "<|mimo_video_start|>",
            "video_end_token_id": "<|mimo_video_end|>"] {
            XCTAssertEqual(vocab[spelling], processor[key] as? Int)
        }
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


    private func makeServer(
        mtp: MTPMode = .off, witness: NativeStandaloneWitness = .init(),
        scannerQuoted: Bool = false,
        observe: (@Sendable (StandaloneNativeMiMoTestHooks.Phase, UUID?) async throws -> Void)? = nil
    ) async throws -> (StandaloneServer, String, MiMoV26NativeLoadRegistry) {
        try lane()
        let root = try fixture()
        let declaration = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        let id = "synthetic-native-standalone-" + UUID().uuidString
        let registry = MiMoV26NativeLoadRegistry()
        let budget = GlobalKVCacheBudget() // Real reader and unchanged default reserves.
        let server = StandaloneServer(config: .init(port: 0, mtpMode: mtp), models: [],
            kvBudgetForTesting: budget, nativeMiMoRegistryForTesting: registry)
        retainedServers.append(server)
        var hooks = StandaloneNativeMiMoTestHooks(modelID: id, directory: root, observe: observe)
        hooks.didClearCache = { witness.cleared() }
        let info: ModelInfo
        if scannerQuoted {
            info = try XCTUnwrap(ModelScanner.parseModelInfo(snapshotDir: root, modelName: id))
            XCTAssertEqual(info.modelType, "mimo_v2")
            XCTAssertGreaterThan(info.sizeBytes, 1)
            XCTAssertGreaterThan(try XCTUnwrap(info.nativeLoadTransientBytes), 0)
            XCTAssertNil(info.ssdOffloadedWeightBytes)
        } else {
            info = .init(id: id, modelType: "mimo_v2", sizeBytes: 1,
                estimatedMemoryGb: declaration.estimatedWeightsGb)
        }
        try await server.installSyntheticNativeMiMoForTesting(info, hooks: hooks)
        return (server, id, registry)
    }

    private func consumer(_ server: StandaloneServer) -> MultiModelBatchSchedulerEngine {
        MultiModelBatchSchedulerEngine(acquire: { try await server.acquireModel($0) },
            tokenizerProvider: { try await server.resolveTokenizer($0) },
            availableModels: { await server.advertisedModelIds() }, defaultMaxTokens: 2)
    }

    private func request(_ id: String) -> OpenAIChatCompletionRequest {
        .init(model: id, messages: [.init(role: .user, content: .text("x"))],
            stream: true, temperature: 0, maxTokens: 2)
    }

    private func actualReceipt(_ witness: NativeStandaloneWitness) async throws -> MiMoV26NativeRetirementReceipt {
        guard let transaction = witness.transaction,
              case .retired(let receipt) = await transaction.retire() else {
            XCTFail("the caller did not produce actual typed retirement")
            throw FixtureError.unexpectedOwner
        }
        return receipt
    }

    func testActualOffCallerPublishesAndStopRetiresSameNativeOwner() async throws {
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness)
        try await server.ensureModelLoaded(id)
        await server.watchNative(id, witness: witness)
        let before = await server.nativeView(id)
        XCTAssertTrue(before.resident); XCTAssertFalse(before.loading)
        XCTAssertEqual(before.transactionPhase, .published); XCTAssertTrue(before.hasBundle)
        XCTAssertFalse(before.mtp); XCTAssertFalse(before.setupActive); XCTAssertFalse(before.controlActive)
        XCTAssertEqual(before.charge, 0, "only the real publication settles the cold setup promise")
        XCTAssertTrue(witness.bundleAlive); XCTAssertTrue(witness.modelAlive)
        await server.stop()
        let after = await server.nativeView(id)
        XCTAssertTrue(after.stopped); XCTAssertFalse(after.resident); XCTAssertFalse(after.loading)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty); XCTAssertEqual(after.charge, 0)
        let receipt = try await actualReceipt(witness)
        XCTAssertEqual(receipt.transactionID, before.transactionID)
        XCTAssertNotNil(receipt.engine)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive)
        XCTAssertFalse(witness.modelAlive)
        // No physical/M equality is inferred from this wrapper lifetime.
        XCTAssertGreaterThan(witness.clearCount, 0)
    }

    func testActualScannerQuotedCallerPublishesAndRetiresWithoutSSDDiscount() async throws {
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, scannerQuoted: true)
        try await server.ensureModelLoaded(id)
        await server.watchNative(id, witness: witness)
        let published = await server.nativeView(id)
        XCTAssertTrue(published.resident); XCTAssertTrue(published.hasBundle)
        XCTAssertEqual(published.transactionPhase, .published)
        XCTAssertEqual(published.charge, 0)
        await server.stop()
        let receipt = try await actualReceipt(witness)
        XCTAssertEqual(receipt.transactionID, published.transactionID)
        XCTAssertNotNil(receipt.engine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        let stopped = await server.nativeView(id)
        XCTAssertFalse(stopped.resident); XCTAssertEqual(stopped.charge, 0)
        witness.dropTransaction()
    }

    func testActualScannerPreloadStartsListenerWithSameNativeOwner() async throws {
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, scannerQuoted: true)
        let summary = await server.preloadSelectedModels(configuredModelIDs: [id])
        XCTAssertEqual(summary.loaded, [id]); XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertTrue(summary.skippedInsufficientMemory.isEmpty)
        await server.watchNative(id, witness: witness)
        let preloaded = await server.nativeView(id)
        let transactionID = try XCTUnwrap(preloaded.transactionID)
        let lifecycle = try await server.nativeMiMoLifecycleForLoad()
        XCTAssertEqual(preloaded.transactionPhase, .published)
        XCTAssertTrue(preloaded.resident); XCTAssertFalse(preloaded.controlActive)
        XCTAssertFalse(preloaded.setupActive)
        try await server.start()
        let bound = await server.waitUntilBound(timeoutSeconds: 10)
        XCTAssertTrue(bound, "the actual start-created listener must bind after preload")
        let serving = await server.nativeView(id)
        let servingLifecycle = try await server.nativeMiMoLifecycleForLoad()
        XCTAssertEqual(serving.transactionID, transactionID)
        XCTAssertEqual(servingLifecycle, lifecycle, "start must not replace the open generation")
        XCTAssertTrue(serving.resident); XCTAssertTrue(serving.hasBundle)
        XCTAssertEqual(serving.transactionPhase, .published)
        await server.stop()
        let stopped = await server.nativeView(id)
        XCTAssertTrue(stopped.stopped); XCTAssertFalse(stopped.resident)
        XCTAssertEqual(stopped.charge, 0); XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        let receipt = try await actualReceipt(witness)
        XCTAssertEqual(receipt.transactionID, transactionID)
        XCTAssertEqual(receipt.lifecycle, lifecycle); XCTAssertNotNil(receipt.engine)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive); XCTAssertFalse(witness.modelAlive)
    }

    func testStartRefusesActualUnpublishedPreloadWithoutReplacingOwner() async throws {
        let gate = NativeStandaloneGate()
        let (server, id, registry) = try await makeServer(scannerQuoted: true, observe: { phase, _ in
            if phase == .beforeWeights { await gate.hold() }
        })
        let loader = Task { try await server.ensureModelLoaded(id) }
        await gate.waitForEntry()
        let held = await server.nativeView(id)
        let lifecycle = try await server.nativeMiMoLifecycleForLoad()
        let transactionID = try XCTUnwrap(held.transactionID)
        XCTAssertTrue(held.loading); XCTAssertTrue(held.controlActive)
        XCTAssertGreaterThan(held.charge, 0); XCTAssertNotEqual(held.transactionPhase, .published)
        do { try await server.start(); XCTFail("listener start accepted an incomplete native preload") }
        catch { XCTAssertTrue(error is StandaloneServerError) }
        let refused = await server.nativeView(id)
        let sameLifecycle = try await server.nativeMiMoLifecycleForLoad()
        XCTAssertTrue(refused.stopped); XCTAssertTrue(refused.loading)
        XCTAssertEqual(refused.transactionID, transactionID)
        XCTAssertEqual(sameLifecycle, lifecycle); XCTAssertEqual(refused.charge, held.charge)
        await gate.release()
        try await loader.value
        await server.stop()
        let stopped = await server.nativeView(id)
        XCTAssertTrue(stopped.stopped); XCTAssertFalse(stopped.resident)
        XCTAssertEqual(stopped.charge, 0); XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testActualOnCallerUsesBuiltEmbeddedHeadAndRetiresWithoutWarmRebuild() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled)
        let (server, id, registry) = try await makeServer(mtp: .on)
        try await server.ensureModelLoaded(id)
        let before = await server.nativeView(id)
        XCTAssertTrue(before.mtp); XCTAssertTrue(before.hasBundle)
        XCTAssertEqual(before.transactionPhase, .published)
        // Existing resident acquisition must not construct another cold pipeline.
        try await server.ensureModelLoaded(id)
        let same = await server.nativeView(id)
        XCTAssertEqual(same.transactionID, before.transactionID)
        await server.stop()
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        let after = await server.nativeView(id)
        XCTAssertTrue(after.stopped); XCTAssertEqual(after.charge, 0)
    }

    func testPreWeightVetoUsesActualNoSubmissionUnwindAndKeepsUnrelatedCharge() async throws {
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, observe: { phase, transactionID in
            if phase == .beforeWeights {
                XCTAssertNotNil(transactionID)
                throw FixtureError.veto
            }
        })
        let budget = await server.kvBudget
        let empty = budget.processLedger.createOwner()
        let other = try budget.processLedger.replaceCharge(owner: empty.owner,
            expectedRevision: empty.revision, expectedPolicyEpoch: budget.processLedger.policySnapshot().epoch,
            chargedBytes: 4096)
        do { try await server.ensureModelLoaded(id); XCTFail("real pre-weight veto ignored") }
        catch { XCTAssertTrue(error is FixtureError) }
        let after = await server.nativeView(id)
        XCTAssertFalse(after.resident); XCTAssertFalse(after.loading)
        XCTAssertEqual(after.charge, 4096)
        XCTAssertEqual(budget.processLedger.state(for: other.owner), other)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertFalse(registry.hasRetainedFault)
        _ = budget.processLedger.retire(other.owner)
        await server.stop()
    }

    func testAfterBundleVetoRetiresActualEngineRatherThanVoidCleanup() async throws {
        let gate = NativeStandaloneGate()
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, observe: { phase, _ in
            if phase == .afterBundle { await gate.hold(); throw FixtureError.veto }
        })
        let loader = Task {
            defer { gate.taskEnded() }
            try await server.ensureModelLoaded(id)
        }
        await gate.waitForEntry()
        await server.watchNative(id, witness: witness)
        let held = await server.nativeView(id)
        XCTAssertTrue(held.hasBundle); XCTAssertTrue(held.loading); XCTAssertFalse(held.resident)
        XCTAssertGreaterThan(held.charge, 0); XCTAssertTrue(witness.bundleAlive)
        await gate.release()
        do { try await loader.value; XCTFail("post-engine veto published") }
        catch { XCTAssertTrue(error is FixtureError) }
        let after = await server.nativeView(id)
        XCTAssertFalse(after.loading); XCTAssertFalse(after.resident); XCTAssertEqual(after.charge, 0)
        let receipt = try await actualReceipt(witness)
        XCTAssertNotNil(receipt.engine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty); XCTAssertFalse(registry.hasRetainedFault)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive)
        await server.stop()
    }

    func testStopClosesBeforeHeldSetupUnwindsAndKeepsBasisUntilActualJoin() async throws {
        let gate = NativeStandaloneGate()
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, observe: { phase, _ in
            if phase == .afterBundle { await gate.hold() }
        })
        let loader = Task {
            defer { gate.taskEnded() }
            try await server.ensureModelLoaded(id)
        }
        await gate.waitForEntry()
        await server.watchNative(id, witness: witness)
        let before = await server.nativeView(id), clears = witness.clearCount
        let stopper = Task { await server.stop() }
        await gate.waitForCancellation() // actual owned task cancellation, not a delay
        let held = await server.nativeView(id)
        XCTAssertTrue(held.stopping); XCTAssertTrue(held.loading); XCTAssertTrue(held.hasBundle)
        XCTAssertEqual(held.charge, before.charge); XCTAssertGreaterThan(held.charge, 0)
        XCTAssertEqual(witness.clearCount, clears); XCTAssertTrue(witness.bundleAlive)
        do { try await server.ensureModelLoaded(id); XCTFail("closing owner admitted another load") }
        catch {}
        await gate.release()
        do { try await loader.value; XCTFail("late cancelled setup published") } catch {}
        await stopper.value
        let after = await server.nativeView(id)
        XCTAssertTrue(after.stopped); XCTAssertFalse(after.loading); XCTAssertFalse(after.resident)
        XCTAssertEqual(after.charge, 0); XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertFalse(registry.hasRetainedFault)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive)
    }

    func testParentCancellationRetainsHeldRealPipelineUntilItsTaskActuallyReturns() async throws {
        let gate = NativeStandaloneGate()
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, observe: { phase, _ in
            if phase == .afterBundle { await gate.hold() }
        })
        let loader = Task {
            defer { gate.taskEnded() }
            try await server.ensureModelLoaded(id)
        }
        await gate.waitForEntry()
        await server.watchNative(id, witness: witness)
        let before = await server.nativeView(id), clears = witness.clearCount
        loader.cancel()
        await gate.waitForCancellation()
        let held = await server.nativeView(id)
        XCTAssertTrue(held.loading); XCTAssertTrue(held.hasBundle)
        XCTAssertEqual(held.charge, before.charge); XCTAssertEqual(witness.clearCount, clears)
        XCTAssertTrue(witness.bundleAlive)
        await gate.release()
        do { try await loader.value; XCTFail("cancelled caller returned success") } catch {}
        let after = await server.nativeView(id)
        XCTAssertFalse(after.loading); XCTAssertFalse(after.resident); XCTAssertEqual(after.charge, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty); XCTAssertFalse(registry.hasRetainedFault)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive)
        await server.stop()
    }

    func testActualSchedulerGenerationCompletesLeaseAndSameOwnerStop() async throws {
        let (server, id, registry) = try await makeServer()
        let scheduler = consumer(server)
        let stream = try await scheduler.streamChatCompletion(request: request(id))
        var info: ServerGenerationInfo?
        for try await event in stream { if case .info(let value) = event { info = value } }
        XCTAssertNotNil(info)
        XCTAssertGreaterThan(info?.completionTokens ?? 0, 0)
        let steps = await server.nativeStepCount(id)
        XCTAssertGreaterThan(steps, 0, "must execute the real native target, not scripted output")
        await server.stop()
        let after = await server.nativeView(id)
        XCTAssertTrue(after.stopped); XCTAssertFalse(after.resident); XCTAssertEqual(after.charge, 0)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testActualIdleEvictionRetiresExactOwnerBeforeAnotherColdLoad() async throws {
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness)
        try await server.ensureModelLoaded(id)
        await server.watchNative(id, witness: witness)
        let before = await server.nativeView(id)
        let evicted = await server.evictLRUIdleSlotForTesting()
        XCTAssertTrue(evicted)
        let after = await server.nativeView(id)
        XCTAssertFalse(after.resident); XCTAssertFalse(after.loading); XCTAssertEqual(after.charge, 0)
        let receipt = try await actualReceipt(witness)
        XCTAssertEqual(receipt.transactionID, before.transactionID)
        XCTAssertNotNil(receipt.engine)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive); XCTAssertFalse(witness.modelAlive)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        // A new real cold load receives a NEW owner/session, not a warm rebuild
        // under a retired permit or a replacement engine under the old contract.
        try await server.ensureModelLoaded(id)
        let reloaded = await server.nativeView(id)
        XCTAssertNotEqual(reloaded.transactionID, before.transactionID)
        XCTAssertEqual(reloaded.transactionPhase, .published)
        await server.stop()
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testRealCallbackTailCannotDisappearAfterLogicalReservationRelease() async throws {
        let callback = NativeStandaloneGate()
        let witness = NativeStandaloneWitness()
        let (server, id, registry) = try await makeServer(witness: witness, observe: { phase, _ in
            if phase == .releaseCallbackTail { await callback.hold() }
        })
        let scheduler = consumer(server)
        let submittedRequest = request(id)
        let generated = Task {
            do {
                let stream = try await scheduler.streamChatCompletion(request: submittedRequest)
                var info: ServerGenerationInfo?
                for try await event in stream { if case .info(let value) = event { info = value } }
                return info
            } catch {
                callback.taskEnded()
                throw error
            }
        }
        await callback.waitForEntry()
        await server.watchNative(id, witness: witness)
        let held = await server.nativeView(id), clears = witness.clearCount
        XCTAssertEqual(held.reservations, 0, "logical release is deliberately already complete")
        XCTAssertEqual(held.consumers, 1, "actual callback-return obligation must remain owned")
        XCTAssertEqual(held.phases, [.releasing])
        XCTAssertTrue(held.resident); XCTAssertTrue(held.hasBundle)
        let stopper = Task { await server.stop() }
        // Cancellation/close does not complete the held callback. The stop's
        // actual lease join must wait without inheriting its TaskLocal identity.
        let firstInfo = try await generated.value
        XCTAssertNotNil(firstInfo)
        let stillHeld = await server.nativeView(id)
        XCTAssertEqual(stillHeld.consumers, 1); XCTAssertTrue(witness.bundleAlive)
        XCTAssertEqual(witness.clearCount, clears)
        await callback.release()
        await stopper.value
        let after = await server.nativeView(id)
        XCTAssertTrue(after.stopped); XCTAssertFalse(after.resident); XCTAssertEqual(after.consumers, 0)
        XCTAssertEqual(after.charge, 0); XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        witness.dropTransaction()
        XCTAssertFalse(witness.bundleAlive)
    }

    func testPendingNativeRetryJoinsOriginalActualServiceTailBeforeStopped() async throws {
        let tail = NativeStandaloneGate()
        let actualExit = NativeServiceExitWitness()
        let enteredJoin = AsyncStream<Void>.makeStream()
        let (server, id, registry) = try await makeServer()
        try await server.setNativeServiceLifecycleHooksForTesting(
            exitTail: {
                await tail.hold()
                // Only the REAL start-created service Task can set this, after
                // its held tail returns and immediately before that Task exits.
                actualExit.finishInsideActualServiceTail()
            },
            beforeJoin: {
                enteredJoin.continuation.yield(); enteredJoin.continuation.finish()
            },
            afterJoin: {
                // Runs synchronously immediately after actual Task.value,
                // before later teardown awaits can mask a skipped/nil join.
                XCTAssertTrue(actualExit.observeActualJoin(),
                    "service Task join returned before its actual held tail exited")
            })
        // This is the ACTUAL start-created Hummingbird service task. Only its
        // final post-runService tail is held; no service/Task/result is replaced.
        try await server.start()
        let bound = await server.waitUntilBound(timeoutSeconds: 10)
        XCTAssertTrue(bound)
        try await server.ensureModelLoaded(id)
        let rawBridge = await server.nativeBridgeForServiceJoinTest(id)
        let bridge = try XCTUnwrap(rawBridge)
        let queue = NativeServiceQueueHold()
        defer { queue.release() }
        let (queueTask, preliminary) = try await beginActualPendingShutdown(bridge, queue: queue)
        // A real concurrent bridge call is awaiting the held real engine queue.
        // The ordinary stop sees genuine pendingConsumers with no SDK proof.
        await server.stop()
        let first = await server.nativeView(id)
        XCTAssertTrue(first.stopping); XCTAssertFalse(first.stopped)
        XCTAssertTrue(first.resident); XCTAssertTrue(first.hasBundle)
        let pending = await server.nativeRetirementForServiceJoinTest(id)
        guard case .pending(.engineProofUnavailable)? = pending else {
            return XCTFail("did not exercise the actual pending-native early return")
        }
        // Release the real native queue promptly; do not keep the default SDK
        // watchdog parked while waiting for Hummingbird's unrelated exit tail.
        queue.release()
        await queueTask.value
        guard case .quiescent = try await preliminary.value else {
            return XCTFail("actual preliminary native shutdown did not complete")
        }
        await tail.waitForEntry() // real service run ended, actual Task still live
        let retained = await server.nativeServiceOwnershipForTesting()
        XCTAssertTrue(retained.stored); XCTAssertTrue(retained.stopping)

        await server.retryNativeAfterActualServiceProgressForTesting(id)
        for await _ in enteredJoin.stream { break }
        // Automatic retry passed serviceTask:nil. The dedicated retained handle
        // must still identify the original Task at its actual join, not nil.
        let joining = await server.nativeServiceOwnershipForTesting()
        let held = await server.nativeView(id)
        XCTAssertTrue(joining.stored); XCTAssertTrue(joining.stopping)
        XCTAssertTrue(held.stopping); XCTAssertFalse(held.stopped)
        XCTAssertFalse(held.resident)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty,
            "native proof is real, but it cannot substitute for the live service join")
        await tail.release()
        await server.waitUntilStopped()
        let finished = await server.nativeView(id)
        let released = await server.nativeServiceOwnershipForTesting()
        XCTAssertTrue(finished.stopped)
        XCTAssertFalse(released.stored); XCTAssertFalse(released.stopping)
        XCTAssertEqual(actualExit.observedJoins, 1, "the post-join invariant must actually run")
    }

    private func beginActualPendingShutdown(
        _ bridge: EngineV2Bridge, queue: NativeServiceQueueHold
    ) async throws -> (Task<Void, Never>, Task<CBv2NativeShutdownOutcome, Error>) {
        let raw = await bridge.ownedEngine
        let actual = try XCTUnwrap(raw as? EngineV2)
        let contract = try XCTUnwrap(actual.nativeShutdownExecutionContractID)
        let blocked = Task.detached {
            actual.loopForTesting.onEngineQueueSync { queue.hold() }
        }
        for await _ in queue.entered.stream { break }
        let shutdown = Task {
            try await bridge.shutdownNativeConstruction(expectedEngine: actual, executionContractID: contract)
        }
        // Ordering only, NOT a drain/completion oracle. Observe the actual actor
        // entered its shutdown before issuing the concurrent actual stop.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let observed = await bridge.nativeRetirementTaskSnapshot()
            if observed.progress[1] == 1, observed.sdkQuiescence == nil {
                return (blocked, shutdown)
            }
            await Task.yield()
        }
        queue.release()
        await blocked.value
        _ = try await shutdown.value
        throw FixtureError.unexpectedOwner
    }

    func testGracefulDrainDoesNotCountAnIdlePublishedNativeOwnerAsActiveWork() async throws {
        let (server, id, registry) = try await makeServer()
        try await server.ensureModelLoaded(id)
        let identity = try XCTUnwrap(ProcessIdentity.current())
        let status = await server.drainForLifecycle(.init(target: identity, timeoutSeconds: 0))
        XCTAssertEqual(status.outcome, .drained)
        XCTAssertEqual(status.remaining, 0)
        let idle = await server.nativeView(id)
        XCTAssertTrue(idle.resident); XCTAssertTrue(idle.hasBundle)
        XCTAssertEqual(idle.transactionPhase, .published,
            "graceful admission closure must not retire a healthy idle owner")
        do { _ = try await server.acquireModel(id); XCTFail("graceful gate admitted a new acquisition") }
        catch {}
        await server.stop()
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
    }

    func testNonforcedGracefulDrainLetsAlreadyBoundPreSubmitRequestFinish() async throws {
        #if DEBUG
        let gate = NativeStandaloneGate()
        let (server, id, registry) = try await makeServer()
        try await server.ensureModelLoaded(id)
        let raw = await server.nativeBridgeForServiceJoinTest(id)
        let bridge = try XCTUnwrap(raw)
        await bridge._testInstallPreSubmitGate { await gate.hold() }
        let scheduler = consumer(server), submittedRequest = request(id)
        let accepted = Task {
            do {
                let stream = try await scheduler.streamChatCompletion(request: submittedRequest)
                var info: ServerGenerationInfo?
                for try await event in stream { if case .info(let value) = event { info = value } }
                return info
            } catch {
                gate.taskEnded()
                throw error
            }
        }
        await gate.waitForEntry() // actual bound preparation, before real engine.submit
        let before = await server.nativeView(id)
        XCTAssertEqual(before.consumers, 1); XCTAssertEqual(before.phases, [.active])
        let identity = try XCTUnwrap(ProcessIdentity.current())
        let timed = await server.drainForLifecycle(.init(target: identity, timeoutSeconds: 0))
        XCTAssertEqual(timed.outcome, .timedOut)
        XCTAssertGreaterThan(timed.remaining, 0)
        let held = await server.nativeView(id)
        XCTAssertEqual(held.transactionID, before.transactionID)
        XCTAssertEqual(held.transactionPhase, .published)
        XCTAssertEqual(held.phases, [.active], "nonforce must not cancel the accepted lease")
        do { _ = try await server.acquireModel(id); XCTFail("newcomer bypassed graceful admission closure") }
        catch {}
        await gate.release()
        let info = try await accepted.value
        XCTAssertNotNil(info); XCTAssertGreaterThan(info?.completionTokens ?? 0, 0)
        let steps = await server.nativeStepCount(id)
        XCTAssertGreaterThan(steps, 0)
        let drained = await server.drainForLifecycle(.init(target: identity, timeoutSeconds: 5))
        XCTAssertEqual(drained.outcome, .drained); XCTAssertEqual(drained.remaining, 0)
        let stillOwned = await server.nativeView(id)
        XCTAssertTrue(stillOwned.resident); XCTAssertEqual(stillOwned.transactionPhase, .published)
        await server.stop()
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        #else
        throw FixtureError.debugSeamsRequired
        #endif
    }

    func testForceStillClosesAndCancelsActualBoundPreSubmitWork() async throws {
        #if DEBUG
        let gate = NativeStandaloneGate()
        let (server, id, registry) = try await makeServer()
        try await server.ensureModelLoaded(id)
        let raw = await server.nativeBridgeForServiceJoinTest(id)
        let bridge = try XCTUnwrap(raw)
        await bridge._testInstallPreSubmitGate { await gate.hold() }
        let scheduler = consumer(server), submittedRequest = request(id)
        let accepted = Task {
            do {
                let stream = try await scheduler.streamChatCompletion(request: submittedRequest)
                for try await _ in stream {}
            } catch { gate.taskEnded(); throw error }
        }
        await gate.waitForEntry()
        let identity = try XCTUnwrap(ProcessIdentity.current())
        let forced = await server.drainForLifecycle(.init(target: identity, timeoutSeconds: 0, force: true))
        XCTAssertEqual(forced.outcome, .forced)
        await gate.waitForCancellation() // actual task cancellation, not deadline inference
        let held = await server.nativeView(id)
        XCTAssertEqual(held.transactionPhase, .cancelling)
        XCTAssertTrue(held.hasBundle); XCTAssertTrue(held.resident)
        XCTAssertTrue(held.phases.contains(.closing))
        await gate.release()
        do { try await accepted.value; XCTFail("force allowed held pre-submit work to finish successfully") }
        catch {}
        await server.stop()
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertFalse(registry.hasRetainedFault, "ordinary force cancellation is not a native fence fault")
        #else
        throw FixtureError.debugSeamsRequired
        #endif
    }
}

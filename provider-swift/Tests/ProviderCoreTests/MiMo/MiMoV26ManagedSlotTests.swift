import Foundation
import MLX
import MLXVLM
import XCTest
@testable import MLXLMCommon
@_spi(Benchmarking) @testable import ProviderCore

private final class MiMoSlotAssemblyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var visited = false
    private var opened = false
    let entered = AsyncStream<Void>.makeStream()
    func visit() {
        condition.lock()
        defer { condition.unlock() }
        guard !visited else { return }
        visited = true
        entered.continuation.yield(); entered.continuation.finish()
        while !opened { condition.wait() }
    }
    func release() {
        condition.lock(); opened = true; condition.broadcast(); condition.unlock()
    }
    func taskEnded() {
        condition.lock(); defer { condition.unlock() }
        if !visited { entered.continuation.finish() }
    }
}

/// Weak object-lifetime witness only: it never owns a native component or mints
/// completion. Reads borrow the actual bundle only within this synchronous call.
private final class MiMoSlotWeakBundleWitness: @unchecked Sendable {
    private let lock = NSLock()
    private weak var bundle: ProviderEngineBundle?
    func observe(_ value: ProviderEngineBundle) { lock.withLock { bundle = value } }
    var isAlive: Bool { lock.withLock { bundle != nil } }
    var hasAssistant: Bool { lock.withLock { bundle?.hasAssistant == true } }
}

private final class MiMoSlotCancellationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var actualEngine = false
    private var actualAssistant = false
    func record(_ snapshot: MiMoV26NativeLoadTransaction.Snapshot) {
        lock.withLock { count += 1; actualEngine = snapshot.hasEngine; actualAssistant = snapshot.hasAssistant }
    }
    var value: (Int, Bool, Bool) { lock.withLock { (count, actualEngine, actualAssistant) } }
}

/// Prepared only. Every positive model/probe/engine/bridge comes from the real
/// tiny filesystem factory/transaction. No successful native result is mocked.
/// Synthetic CPU fixture transforms are bounded and never touch real artifacts.
final class MiMoV26ManagedSlotTests: XCTestCase {
    private enum FixtureError: Error { case nativeLaneRequired, payloadFixtureRequired, unexpectedRetirement }
    private let literal = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
    private let environment = ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"]
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        // An unexpected failed/pending test must not destroy its last actual
        // owner. The qualification runner must stop that process's native matrix.
        for registry in registries where !registry.retainedTransactionIDs.isEmpty {
            _ = Unmanaged.passRetained(registry)
        }
        registries = []
        super.tearDown()
    }
    private struct Loaded: Sendable {
        let root: URL
        let load: MiMoV26ServingLoad
        let transaction: MiMoV26NativeLoadTransaction
        let registry: MiMoV26NativeLoadRegistry
        let budget: GlobalKVCacheBudget
        let container: ProviderModelContainer
        let tokenizer: TokenizerHandle
        let sizing: SlotSizingSnapshot
    }
    private func fixture(float32: Bool = false, asymmetric: Bool = false) throws -> URL {
        guard let source = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw FixtureError.payloadFixtureRequired
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-serving-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        if float32 || asymmetric {
            try rewriteSyntheticAdmissionFixture(root, float32: float32, asymmetric: asymmetric)
        }
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
        // Actual BPE implementation, finite vocab within the tiny model's128 IDs.
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

    /// Future native-test setup only, never run by this source worker. Changes
    /// only this test's temporary tiny fixture, not the selected artifact or
    /// production numerics. Repeated affine codes/scales preserve the synthetic
    /// storage format; no quantization or second production parameter tree.
    private func rewriteSyntheticAdmissionFixture(_ root: URL, float32: Bool, asymmetric: Bool) throws {
        try lane()
        let configURL = root.appendingPathComponent("config.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        guard config["hidden_size"] as? Int == 64, config["num_hidden_layers"] as? Int == 2,
            config["v_head_dim"] as? Int == 32, config["swa_v_head_dim"] as? Int == 32 else {
            throw FixtureError.payloadFixtureRequired
        }
        if float32 { config["dtype"] = "float32" }
        if asymmetric { config["v_head_dim"] = 64; config["swa_v_head_dim"] = 64 }
        let indexURL = root.appendingPathComponent("model.safetensors.index.json")
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        let mapping = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let originalBytes = try XCTUnwrap(metadata["total_size"] as? Int)
        guard (1...(4 << 20)).contains(originalBytes),
            Set(mapping.values) == Set(["target.safetensors", "vision.safetensors", "audioPatch.safetensors", "model-mtp.safetensors"]) else {
            throw FixtureError.payloadFixtureRequired
        }
        var total = 0
        for name in Set(mapping.values).sorted() {
            let original = root.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let bytes = attributes[.size] as? NSNumber, bytes.uint64Value <= (4 << 20) else {
                throw FixtureError.payloadFixtureRequired
            }
            let arrays = try MLX.loadArrays(url: original, stream: .cpu)
            var transformed: [String: MLXArray] = [:]
            for (key, input) in arrays {
                var array = input
                if float32, [.bfloat16, .float16].contains(array.dtype) {
                    array = array.asType(.float32, stream: .cpu)
                }
                if asymmetric, key.hasPrefix("model.layers.") || key.hasPrefix("mtp.layers.") {
                    if key.contains(".self_attn.v_proj.") {
                        array = concatenated([array, array], axis: 0, stream: .cpu)
                    } else if key.contains(".self_attn.o_proj.") {
                        array = concatenated([array, array], axis: 1, stream: .cpu)
                    }
                }
                transformed[key] = array; total += array.nbytes
            }
            // Materialize the small synthetic CPU roots before replacing their
            // backing file, so a lazy Load never reads a truncated source.
            try withError { error in eval(Array(transformed.values)); try error.check() }
            let replacement = root.appendingPathComponent("replacement-" + UUID().uuidString + ".safetensors")
            // Keep optional safetensors metadata a string map: the native
            // writer otherwise emits null for an empty metadata dictionary.
            try MLX.save(arrays: transformed, metadata: ["fixture": "mimo-admission-geometry"],
                url: replacement, stream: .cpu)
            _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
        }
        index["metadata"] = ["total_size": total]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: indexURL)
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: configURL)
    }


    private func lane() throws {
        guard ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1" else {
            throw FixtureError.nativeLaneRequired
        }
    }
    private func loaded(float32: Bool = false, asymmetric: Bool = false) async throws -> Loaded {
        try lane()
        let root = try fixture(float32: float32, asymmetric: asymmetric)
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        let registry = MiMoV26NativeLoadRegistry()
        registries.append(registry)
        // Preserve real allocator/OS observations and normal activation/OS/KV
        // reserves. No zero-usage admission oracle or lower floor is used here.
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let container = try await load.load()
        let transaction = try XCTUnwrap(load.transaction)
        return .init(root: root, load: load, transaction: transaction, registry: registry,
            budget: budget, container: container,
            tokenizer: await container.tokenizerHandle(modelType: "mimo_v2", directory: root),
            sizing: await container.sizing(modelPath: root, defaultMaxTokens: 32))
    }
    private func prepare(_ value: Loaded, mode: MTPMode,
                         environment: [String: String]? = nil) async throws -> (SpecDecPreparation, EngineV2ServingPreparation) {
        let environment = environment ?? self.environment
        let intent = try MiMoV26ServingLoad.preparation(mode: mode, externalPath: nil, environment: environment)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: "managed-mimo-fixture",
            isVLM: false, modelDirectory: value.root, container: value.container, specDecPreparation: intent)
        return (intent, prepared)
    }
    private func build(_ value: Loaded, intent: SpecDecPreparation, prepared: EngineV2ServingPreparation,
                       backend: String = "contiguous", budget: GlobalKVCacheBudget? = nil,
                       environment: [String: String]? = nil,
                       emit: (@Sendable (TelemetryEvent) -> Void)? = nil) async throws -> ProviderEngineBundle {
        try await EngineV2SlotFactory.makeProductionBundle(modelId: "managed-mimo-fixture", modelType: "mimo_v2",
            isVLM: false, modelDirectory: value.root, container: value.container, tokenizer: value.tokenizer,
            sizing: value.sizing, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2,
            kvBudget: budget ?? value.budget, kvBackendConfig: backend,
            specDecPreparation: intent, preparedModel: prepared, environment: environment ?? self.environment,
            startServingTelemetry: false, emitTelemetry: emit ?? { _ in })
    }
    private func retire(_ value: Loaded) async throws -> MiMoV26NativeRetirementReceipt {
        let result = await value.load.finishFailureAfterUnwind()
        guard case .retired(let receipt) = result else {
            // Unexpected real failed work remains reachable until this test
            // process exits; never turn an unknown outcome into a passed cell.
            if value.registry.hasRetainedFault { _ = Unmanaged.passRetained(value.registry) }
            XCTFail("actual transaction did not retire: \(result)")
            throw FixtureError.unexpectedRetirement
        }
        return receipt
    }
    private func engine(_ bundle: ProviderEngineBundle) async throws -> EngineV2 {
        let value = await bundle.bridge.ownedEngine
        return try XCTUnwrap(value as? EngineV2)
    }

    func testPreparationIsOnlyMetadataUntilOneActualPipelineBuilds() async throws {
        let value = try await loaded()
        let before = value.transaction.snapshot()
        let (intent, prepared) = try await prepare(value, mode: .on)
        XCTAssertTrue(intent.status.configured)
        XCTAssertFalse(prepared.mtpStatus.active)
        XCTAssertNil(prepared.assistant); XCTAssertEqual(prepared.assistantBytes, 0)
        guard case .nativeMiMo(let native) = prepared else { return XCTFail("wrong family") }
        XCTAssertTrue(native.load === value.load); XCTAssertTrue(native.transaction === value.transaction)
        XCTAssertTrue(native.container === value.container.autoregressive)
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch, before.constructionEpoch)
        XCTAssertFalse(value.transaction.snapshot().hasAssistant)
        XCTAssertFalse(value.transaction.snapshot().hasEngine); XCTAssertFalse(value.transaction.snapshot().hasBridge)
        _ = try await retire(value)
    }

    func testOffUsesOneTrackedTargetOnlyPipelineWithoutExtraWeightCharge() async throws {
        for mode in [MTPMode.off] {
            let value = try await loaded()
            let (intent, prepared) = try await prepare(value, mode: mode)
            let epoch = value.transaction.snapshot().constructionEpoch
            let bundle = try await build(value, intent: intent, prepared: prepared)
            let engine = try await engine(bundle)
            XCTAssertFalse(bundle.mtpStatus.active); XCTAssertFalse(bundle.mtpStatus.configured)
            XCTAssertFalse(bundle.hasAssistant); XCTAssertEqual(bundle.assistantBytes, 0)
            XCTAssertNil(engine.mtpMetricsSnapshot())
            XCTAssertNotNil(engine.nativeShutdownExecutionContractID)
            XCTAssertEqual(value.transaction.snapshot().constructionEpoch, epoch + 1)
            XCTAssertTrue(value.transaction.snapshot().hasEngine); XCTAssertTrue(value.transaction.snapshot().hasBridge)
            XCTAssertFalse(value.transaction.snapshot().hasAssistant)
            let stops = await bundle.bridge.stopTokenIds
            XCTAssertEqual(stops, [1, 13])
            let receipt = try await retire(value)
            XCTAssertEqual(receipt.engine?.engineID, engine.nativeShutdownEngineID)
            XCTAssertEqual(receipt.engine?.executionContractID, engine.nativeShutdownExecutionContractID)
            XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
        }
    }

    func testAutoAndOnReportOnlyTheActualEmbeddedHeadAndBoundedSerialDriver() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled, "ON cell requires the actual SDK MTP lane to be enabled")
        for mode in [MTPMode.auto, .on] {
            let value = try await loaded()
            let (intent, prepared) = try await prepare(value, mode: mode)
            XCTAssertFalse(prepared.mtpStatus.active); XCTAssertNil(prepared.assistant)
            let bundle = try await build(value, intent: intent, prepared: prepared)
            let engine = try await engine(bundle)
            XCTAssertTrue(bundle.mtpStatus.active); XCTAssertTrue(bundle.hasAssistant)
            XCTAssertTrue(value.transaction.snapshot().hasAssistant)
            XCTAssertEqual(bundle.assistantBytes, 0, "embedded head is already in the complete loaded weight tree")
            XCTAssertGreaterThan(bundle.mtpStatus.assistantBytes, 0)
            XCTAssertEqual(bundle.mtpStatus.source, .inline)
            XCTAssertEqual(bundle.mtpStatus.sourceRevision, value.load.request.binding.sourceRevision)
            XCTAssertEqual(engine.mtpMetricsSnapshot()?.verificationMode, .serialTarget)
            XCTAssertNil(engine.mtpInactiveReason)
            guard case .bounded? = engine.resolvedMTPAdmission else { return XCTFail("real head has no bounded admission") }
            let status = await bundle.bridge.mtpStatusSnapshot()
            XCTAssertTrue(status.active)
            _ = try await retire(value)
            XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
        }
    }

    func testCurrentKillSwitchVetoesCachedOnIntentWithoutCreatingAnAssistant() async throws {
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .on)
        var disabled = environment; disabled["DARKBLOOM_CBV2_MTP"] = "0"
        let bundle = try await build(value, intent: intent, prepared: prepared, environment: disabled)
        let engine = try await engine(bundle)
        XCTAssertFalse(bundle.mtpStatus.active)
        XCTAssertEqual(bundle.mtpStatus.reason, .killSwitchDisabled)
        XCTAssertFalse(bundle.hasAssistant); XCTAssertFalse(value.transaction.snapshot().hasAssistant)
        XCTAssertNil(engine.mtpMetricsSnapshot())
        _ = try await retire(value)
    }

    private func assertActualGeometry(float32: Bool, mtp: Bool) async throws {
        let value = try await loaded(float32: float32, asymmetric: true)
        let (intent, prepared) = try await prepare(value, mode: mtp ? .on : .off)
        let bundle = try await build(value, intent: intent, prepared: prepared)
        let engine = try await engine(bundle)
        let width = float32 ? 4 : 2
        let rate = (32 + 64) * width, ring = 8 * rate
        XCTAssertEqual(engine.layerKinds.map(\.headDim), [32, 32])
        XCTAssertEqual(engine.layerKinds.map(\.valueHeadDim), [64, 64])
        XCTAssertEqual(engine.layerKinds[0].attention, .full)
        XCTAssertEqual(engine.layerKinds[1].attention, .slidingWindow(8))
        // Actual engine created from the real probe, not a standalone policy helper.
        XCTAssertEqual(engine.admissionForTesting.fullKVBytesPerToken, rate)
        let sharedRate = await bundle.bridge.kvBytesPerToken
        let sharedFixed = await bundle.bridge.fixedRequestBytes
        XCTAssertEqual(sharedRate, rate, "bounded head must not reintroduce context-linear target tax")
        XCTAssertEqual(sharedFixed, ring + engine.resolvedFixedBytesPerRequest)
        XCTAssertEqual(engine.admissionForTesting.fixedBytesPerRequest, engine.resolvedFixedBytesPerRequest)
        XCTAssertEqual(bundle.assistantBytes, 0)
        if mtp {
            XCTAssertGreaterThan(engine.resolvedFixedBytesPerRequest, 0)
            guard case .bounded? = engine.resolvedMTPAdmission else { return XCTFail("missing bounded head") }
        } else {
            XCTAssertEqual(engine.resolvedFixedBytesPerRequest, 0)
            for n in [1, 7, 8, 9, 128] {
                XCTAssertEqual(engine.admissionForTesting.allocatedBytes(forTokens: n), rate * n + ring)
                let shared = await bundle.bridge.requestReservationBytes(tokenCount: n)
                XCTAssertEqual(shared, rate * n + ring)
            }
        }
        _ = try await retire(value)
    }
    func testBF16AsymmetricActualInternalAndSharedTargetRingCharges() async throws {
        try await assertActualGeometry(float32: false, mtp: false)
    }
    func testFP32AsymmetricActualInternalAndSharedTargetRingCharges() async throws {
        try await assertActualGeometry(float32: true, mtp: false)
    }
    func testFP32AsymmetricActualBoundedHeadAddsFixedChargeExactlyOnce() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled)
        try await assertActualGeometry(float32: true, mtp: true)
    }

    func testForeignPreparedOwnerAndForeignBudgetRefuseBeforeNativeAssembly() async throws {
        let a = try await loaded(), b = try await loaded()
        let (intent, preparedA) = try await prepare(a, mode: .off)
        let (_, preparedB) = try await prepare(b, mode: .off)
        let epochA = a.transaction.snapshot().constructionEpoch
        do { _ = try await build(a, intent: intent, prepared: preparedB); XCTFail("foreign preparation accepted") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .nativeOwnerMismatch) }
        do { _ = try await build(a, intent: intent, prepared: preparedA, budget: b.budget); XCTFail("foreign budget accepted") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .nativeOwnerMismatch) }
        let changedIntent = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil, environment: environment)
        do { _ = try await build(a, intent: changedIntent, prepared: preparedA); XCTFail("cached OFF preparation accepted as ON") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .nativeOwnerMismatch) }
        XCTAssertEqual(a.transaction.snapshot().constructionEpoch, epochA)
        XCTAssertFalse(a.transaction.snapshot().hasEngine); XCTAssertFalse(b.transaction.snapshot().hasEngine)
        _ = try await retire(a); _ = try await retire(b)
    }

    func testUnsupportedBackendRefusesBeforeAnyAssistantOrEngineAndPreservesOwner() async throws {
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .on)
        let before = value.transaction.snapshot()
        do { _ = try await build(value, intent: intent, prepared: prepared, backend: "paged"); XCTFail("unqualified paging accepted") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .unsupportedBackend) }
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch, before.constructionEpoch)
        XCTAssertFalse(value.transaction.snapshot().hasAssistant); XCTAssertFalse(value.transaction.snapshot().hasEngine)
        XCTAssertEqual(value.load.snapshot()?.lifecycle, .setup)
        _ = try await retire(value)
    }

    func testWarmRecoveryRefusesBeforeReleasingActualAssistantOrEngine() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled)
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .on)
        let bundle = try await build(value, intent: intent, prepared: prepared)
        let engine = try await engine(bundle)
        let actualAssistant = try XCTUnwrap(bundle.takeAssistantForRecovery())
        XCTAssertNotNil(actualAssistant.drafter)
        let owner = value.load.snapshot()?.ownerState
        do {
            _ = try await EngineV2SlotFactory.prepareRecoveryModel(modelId: "managed-mimo-fixture", isVLM: false,
                modelDirectory: value.root, container: value.container, previousArtifact: nil,
                previousStatus: bundle.mtpStatus, assistant: actualAssistant)
            XCTFail("warm native rebuild accepted")
        } catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .warmRebuildUnsupported) }
        XCTAssertNotNil(actualAssistant.drafter, "refusal must precede explicit release")
        XCTAssertNotNil(engine.mtpMetricsSnapshot())
        XCTAssertEqual(value.load.snapshot()?.ownerState, owner)
        XCTAssertTrue(value.transaction.snapshot().hasAssistant)
        _ = try await retire(value)
        XCTAssertNil(actualAssistant.drafter, "only real retirement releases the same registered handle")
    }

    func testSecondAssemblyRefusalDoesNotRevokeOrReplaceExistingPipeline() async throws {
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .off)
        let bundle = try await build(value, intent: intent, prepared: prepared)
        let original = try await engine(bundle)
        let epoch = value.transaction.snapshot().constructionEpoch
        do { _ = try await build(value, intent: intent, prepared: prepared); XCTFail("second pipeline accepted") }
        catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .slotAssemblyAlreadyClaimed) }
        XCTAssertNoThrow(try value.load.recheck())
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch, epoch)
        let stillOwned = try await engine(bundle)
        XCTAssertTrue(stillOwned === original)
        XCTAssertEqual(value.load.snapshot()?.lifecycle, .setup)
        _ = try await retire(value)
    }

    func testConcurrentSecondAssemblyCannotAdvanceEpochOrCancelFirstPipeline() async throws {
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .off)
        let gate = MiMoSlotAssemblyGate(), env = environment
        defer { gate.release() }
        let first = Task {
            defer { gate.taskEnded() }
            return try await EngineV2SlotFactory.makeProductionBundle(modelId: "managed-mimo-fixture", modelType: "mimo_v2",
                isVLM: false, modelDirectory: value.root, container: value.container, tokenizer: value.tokenizer,
                sizing: value.sizing, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2,
                kvBudget: value.budget, specDecPreparation: intent, preparedModel: prepared,
                environment: env, startServingTelemetry: false, emitTelemetry: { event in
                    if (event.fields?["operation"]?.value as? String) == "engine_v2_kv_backend" { gate.visit() }
                })
        }
        for await _ in gate.entered.stream { break }
        let epoch = value.transaction.snapshot().constructionEpoch
        do { _ = try await build(value, intent: intent, prepared: prepared); XCTFail("concurrent second pipeline accepted") }
        catch { XCTAssertEqual(error as? MiMoV26NativeTransactionError, .slotAssemblyAlreadyClaimed) }
        XCTAssertNoThrow(try value.load.recheck())
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch, epoch)
        gate.release()
        let bundle = try await first.value
        let actual = await bundle.bridge.ownedEngine
        XCTAssertNotNil(actual)
        XCTAssertFalse(value.registry.hasRetainedFault)
        _ = try await retire(value)
    }

    func testCallerFinalVetoKeepsActualBundleAndAssistantUntilConfirmedRetirement() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled)
        let value = try await loaded()
        let (intent, prepared) = try await prepare(value, mode: .on)
        let transaction = value.transaction, env = environment
        let charge = value.budget.processLedger.snapshot().chargedBytes
        let witness = MiMoSlotWeakBundleWitness()
        do {
            _ = try await transaction.performSetup {
                // Call the actual factory through the same larger setup wrapper
                // used by production callers. No test owner stores this bundle.
                let bundle = try await EngineV2SlotFactory.makeProductionBundle(
                    modelId: "managed-mimo-fixture", modelType: "mimo_v2", isVLM: false,
                    modelDirectory: value.root, container: value.container, tokenizer: value.tokenizer,
                    sizing: value.sizing, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2,
                    kvBudget: value.budget, specDecPreparation: intent, preparedModel: prepared,
                    environment: env, startServingTelemetry: false)
                witness.observe(bundle)
                XCTAssertTrue(bundle.hasAssistant)
                XCTAssertTrue(transaction.snapshot().hasBundle)
                value.load.revoke()
                // The OUTER performSetup final recheck throws after this real
                // return. Only the transaction may keep the bundle afterward.
                return bundle
            }
            XCTFail("outer cancelled setup returned a serving bundle")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(witness.isAlive)
        XCTAssertTrue(witness.hasAssistant)
        XCTAssertTrue(transaction.snapshot().hasBundle)
        XCTAssertTrue(transaction.snapshot().hasAssistant)
        XCTAssertTrue(transaction.snapshot().hasEngine)
        XCTAssertTrue(transaction.snapshot().hasBridge)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, charge)
        XCTAssertFalse(value.registry.hasRetainedFault, "cancellation alone is not a permanent native fault")
        let receipt = try await retire(value)
        XCTAssertNotNil(receipt.engine)
        XCTAssertFalse(transaction.snapshot().hasBundle)
        XCTAssertFalse(witness.isAlive)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testRealPostEngineTelemetryCancellationUsesOutcomeRetirementNotVoidShutdown() async throws {
        XCTAssertTrue(CBv2MTPConfig.envEnabled)
        let value = try await loaded()
        let other = value.budget.processLedger.createOwner()
        let unchanged = try value.budget.processLedger.replaceCharge(owner: other.owner,
            expectedRevision: other.revision, expectedPolicyEpoch: value.budget.processLedger.policySnapshot().epoch,
            chargedBytes: 4096)
        let (intent, prepared) = try await prepare(value, mode: .on)
        let load = value.load, transaction = value.transaction
        let witness = MiMoSlotCancellationWitness()
        do {
            _ = try await build(value, intent: intent, prepared: prepared, emit: { event in
                if (event.fields?["operation"]?.value as? String) == "engine_v2_kv_backend" {
                    witness.record(transaction.snapshot())
                    load.revoke()
                }
            })
            XCTFail("late cancellation published a bundle")
        } catch {}
        XCTAssertEqual(witness.value.0, 1)
        XCTAssertTrue(witness.value.1); XCTAssertTrue(witness.value.2)
        // makeBridge's real backend event happens after engine construction.
        // The factory must keep and drain that actual engine and new bridge.
        guard case .retired(let receipt) = await value.load.finishFailureAfterUnwind() else {
            return XCTFail("real failed construction was not retired")
        }
        XCTAssertNotNil(receipt.engine)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 4096)
        XCTAssertEqual(value.budget.processLedger.state(for: other.owner), unchanged)
        XCTAssertFalse(value.registry.hasRetainedFault)
        _ = value.budget.processLedger.retire(other.owner)
    }
}

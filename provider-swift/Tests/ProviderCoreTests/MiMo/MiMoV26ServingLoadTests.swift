import Foundation
import MLX
@testable import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import XCTest
@_spi(Benchmarking) @testable import ProviderCore

private enum MiMoServingTestOwnershipError: Error { case retirementUnproven }

/// Owns actual test resources, never an asserted completion flag. The registry
/// owns each real Task until its result, and the test retains returned bundles
/// until the actual SDK/host retirement succeeds. This is additional test
/// lifetime protection, not a substitute for production transaction ownership.
private final class MiMoServingTestOwner: @unchecked Sendable {
    let registry: MiMoV26NativeLoadRegistry
    let lifecycle: MiMoV26NativeLifecycle
    private let lock = NSLock()
    private var bundles: [ProviderEngineBundle] = []

    init() throws {
        let registry = MiMoV26NativeLoadRegistry()
        self.registry = registry
        lifecycle = try registry.openLifecycle()
    }
    func retain(_ bundle: ProviderEngineBundle) {
        lock.withLock { bundles.append(bundle) }
    }
    func setup<Result: Sendable>(
        _ load: MiMoV26ServingLoad,
        _ body: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let transaction = try XCTUnwrap(load.transaction)
        let task = try registry.launchOwnedTask(for: transaction) {
            try await transaction.performSetup(body)
        }
        return try await withTaskCancellationHandler {
            let result = await task.result
            // This caller is outside the registered task; never self-await it.
            await registry.joinOwnedTasksFromOutside(transaction)
            let value = try result.get()
            try Task.checkCancellation()
            return value
        } onCancel: {
            load.revoke()
            task.cancel()
        }
    }
    func load(_ load: MiMoV26ServingLoad, from root: URL) async throws -> ProviderModelContainer {
        try await setup(load) {
            try await ModelContainerLoading.loadServingContainer(from: root, nativeMiMoLoad: load)
        }
    }
    @discardableResult
    func retire(_ load: MiMoV26ServingLoad) async throws -> MiMoV26NativeRetirementReceipt {
        load.revoke()
        if let transaction = load.transaction {
            await registry.joinOwnedTasksFromOutside(transaction)
        }
        let outcome = await load.finishFailureAfterUnwind()
        guard case .retired(let receipt) = outcome else {
            // Pending is NOT converted into a fault or a successful receipt.
            // tearDown retains this actual owner until the test process exits.
            XCTFail("actual native retirement remains unproven: \(outcome)")
            throw MiMoServingTestOwnershipError.retirementUnproven
        }
        let retiredBundles = lock.withLock {
            let previous = bundles
            bundles = []
            return previous
        }
        withExtendedLifetime(retiredBundles) {}
        return receipt
    }
}

private final class MiMoAdmissionUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var controlled = false
    // Real allocator counters for load/probe/receipt settlement (OS available
    // remains the explicit test-oracle "unknown" value). Only after setup retires do
    // logical-admission tests select a zero-usage oracle; this is NOT a process
    // peak/physical-coverage measurement and creates no materialized-M credit.
    func useControlledAdmissionUsage() { lock.withLock { controlled = true } }
    func read() -> GlobalKVCacheBudget.MemorySnapshot {
        if lock.withLock({ controlled }) {
            return .init(total: ProcessInfo.processInfo.physicalMemory, active: 0, cache: 0, systemAvailable: .max)
        }
        let sample = Memory.snapshot()
        return .init(total: ProcessInfo.processInfo.physicalMemory,
            active: UInt64(max(0, sample.activeMemory)), cache: UInt64(max(0, sample.cacheMemory)), systemAvailable: .max)
    }
}

private final class MiMoAdmissionTerminalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var terminal: CBv2Usage?
    var usage: CBv2Usage? { lock.withLock { terminal } }
    func enter(_ value: CBv2Usage) async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                terminal = value
                if opened { return true }
                waiter = continuation; return false
            }
            if resume { continuation.resume() }
        }
    }
    func open() {
        let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !opened else { return nil }
            opened = true; let value = waiter; waiter = nil; return value
        }
        parked?.resume()
    }
}

/// Prepared, not executed by the source worker. These use the real strict
/// filesystem/serial factory, LocalTokenizerLoader/Jinja and shared ledger.
/// The tiny BPE/template are synthetic routing fixtures, NOT official prompt
/// parity or full-artifact/model-quality evidence. Native cases opt in; enabled
/// gates fail if their bounded fixture is missing or invalid.
final class MiMoV26ServingLoadTests: XCTestCase {
    private enum FixtureError: Error { case payloadFixtureRequired, debugSeamsRequired, waitExpired }
    private let literal = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
    private var nativeOwners: [MiMoServingTestOwner] = []
    private var metadataRegistries: [MiMoV26NativeLoadRegistry] = []

    override func tearDown() {
        for owner in nativeOwners {
            XCTAssertNoThrow(try owner.registry.closeLifecycle(owner.lifecycle))
            if owner.registry.hasRetainedFault || !owner.registry.retainedTransactionIDs.isEmpty {
                _ = Unmanaged.passRetained(owner)
            }
        }
        for registry in metadataRegistries
            where registry.hasRetainedFault || !registry.retainedTransactionIDs.isEmpty {
            _ = Unmanaged.passRetained(registry)
        }
        nativeOwners = []; metadataRegistries = []
        super.tearDown()
    }

    private func claim(_ load: MiMoV26ServingLoad, budget: GlobalKVCacheBudget) throws -> MiMoServingTestOwner {
        let owner = try MiMoServingTestOwner()
        nativeOwners.append(owner) // Retain even a partially refused real claim.
        try load.claim(budget: budget, lifecycle: owner.lifecycle, registry: owner.registry)
        return owner
    }

    private func fixture(float32: Bool = false, asymmetric: Bool = false) throws -> URL {
        guard let source = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw FixtureError.payloadFixtureRequired
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-serving-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("tiny-bf16"), to: root)
        // Preserve bounded synthetic payloads until the owned test process
        // exits. A failing native gate can retain lazy Load roots, so generic
        // XCTest teardown must not unlink their backing files.
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
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS")
    }
    private func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(activationReserveBytes: 256 << 20)
    }

    func testExactNativeSelectionPreservesOldFamiliesAndRequiresManagedLoad() async throws {
        XCTAssertEqual(ModelContainerLoading.factorySelection(for: ["model_type": "mimo_v2"]), .nativeMiMo)
        XCTAssertEqual(ModelContainerLoading.factorySelection(for: ["model_type": "llama"]), .text)
        XCTAssertEqual(ModelContainerLoading.factorySelection(for: ["model_type": "mimo_v2_typo"]), .text)
        let root = try fixture()
        do { _ = try await ModelContainerLoading.loadServingContainer(from: root); XCTFail("bare native load accepted") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .managedLoadRequired) }
        do { _ = try await ModelContainerLoading.loadContainer(from: root); XCTFail("generic factory selected") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .managedLoadRequired) }
    }

    func testDescriptorBindsHistoricalOriginAndAllComponentsWithoutPayloadAuthentication() throws {
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        XCTAssertEqual(load.request.binding.sourceRevision, String(repeating: "a", count: 40))
        XCTAssertEqual(load.request.binding.scope, "root-bundle-only")
        XCTAssertNil(load.request.binding.payloadVerificationReceiptSHA256)
        XCTAssertEqual(Set(load.plan.bundlePlan.components.keys), [.target, .vision, .audioPatch, .mtp])
        XCTAssertFalse(load.plan.bundlePlan.provenance.artifactID.contains(root.path))
        XCTAssertEqual(load.request.binding.conversionManifestSHA256,
            MiMoV26ServingLoad.hash(try Data(contentsOf: root.appendingPathComponent("conversion_manifest.json"))))
        var changed = try Data(contentsOf: root.appendingPathComponent("conversion_manifest.json"))
        changed.append(10)
        try changed.write(to: root.appendingPathComponent("conversion_manifest.json"))
        XCTAssertThrowsError(try load.validateDescriptor())
    }

    func testMetadataReaderRefusesSymlinkAndPreAllocationOversize() throws {
        let root = try fixture(), source = root.appendingPathComponent("conversion_manifest.json")
        let link = root.appendingPathComponent("manifest-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try MiMoV26ServingLoad.readMetadata(link, limit: 1 << 20))
        XCTAssertThrowsError(try MiMoV26ServingLoad.readMetadata(source, limit: 1))
    }

    func testExplicitOnOffAutoAndKillSwitchDoNotAddExternalWeights() throws {
        let on = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil, environment: [:])
        XCTAssertTrue(on.status.configured); XCTAssertNil(on.status.reason); XCTAssertNil(on.artifact)
        let automatic = try MiMoV26ServingLoad.preparation(mode: .auto, externalPath: nil, environment: [:])
        XCTAssertTrue(automatic.status.configured); XCTAssertNil(automatic.status.reason)
        XCTAssertEqual(automatic.status.source, .inline); XCTAssertNil(automatic.artifact)
        for mode in [MTPMode.off] {
            let value = try MiMoV26ServingLoad.preparation(mode: mode, externalPath: nil, environment: [:])
            XCTAssertFalse(value.status.configured); XCTAssertNil(value.artifact)
        }
        let killed = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil,
            environment: ["DARKBLOOM_CBV2_MTP": "0"])
        XCTAssertEqual(killed.status.reason, .killSwitchDisabled)
        XCTAssertThrowsError(try MiMoV26ServingLoad.preparation(mode: .on, externalPath: "external"))
        let killedAuto = try MiMoV26ServingLoad.preparation(mode: .auto, externalPath: nil,
            environment: ["DARKBLOOM_CBV2_MTP": "0"])
        XCTAssertEqual(killedAuto.status.reason, .killSwitchDisabled)
        let absentAuto = try MiMoV26ServingLoad.preparation(mode: .auto, externalPath: nil,
            environment: [:], embeddedArtifactDeclared: false)
        XCTAssertFalse(absentAuto.status.configured); XCTAssertNil(absentAuto.artifact)
        let absentOn = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil,
            environment: [:], embeddedArtifactDeclared: false)
        XCTAssertEqual(absentOn.status.reason, .metadataMissing)
        XCTAssertTrue(try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: fixture())).hasEmbeddedMTP)
    }

    func testNativeBenchmarkPagedRefusesBeforeMetadataOrBudgetAllocation() async throws {
        do {
            _ = try await EngineV2Factory.loadNativeMiMoBenchmarkSession(modelID: "synthetic-native-mimo",
                directory: URL(fileURLWithPath: "/nonexistent-native-fixture"),
                verifiedWeightHash: String(repeating: "a", count: 64),
                operatorReserveBytes: 4 << 30, kvBackend: "paged")
            XCTFail("unqualified paging reached native benchmark loading")
        } catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .unsupportedBackend) }
    }

    func testRealFactoryReceiptKeepsSetupChargeAndOtherOwnerUntilFinalAccounting() async throws {
        try lane()
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root)), budget = budget()
        let ledger = budget.processLedger, empty = ledger.createOwner()
        let other = try ledger.replaceCharge(owner: empty.owner, expectedRevision: empty.revision,
            expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: 1234)
        let owner = try claim(load, budget: budget)
        let initial = try XCTUnwrap(load.snapshot()?.ownerState)
        XCTAssertEqual(initial.chargedBytes, load.request.requiredLoadBytes + UnifiedMemoryCap.minimumLoadKVBytes)
        XCTAssertEqual(ledger.snapshot().ownerCount, 2)
        var container: ProviderModelContainer? = try await owner.load(load, from: root)
        XCTAssertEqual(load.snapshot()?.lifecycle, .setup)
        XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, UnifiedMemoryCap.minimumLoadKVBytes)
        XCTAssertEqual(ledger.state(for: other.owner), other)
        let returnedContainer = try XCTUnwrap(container?.autoregressive)
        let actualReceipt = try await owner.setup(load) {
            try await returnedContainer.perform { context in
                try XCTUnwrap(context.model as? MiMoV26LoadedModel).loadReceipt
            }
        }
        XCTAssertEqual(actualReceipt.sessionID, load.request.sessionID)
        XCTAssertFalse(actualReceipt.payloadHashesRecomputed)
        do { _ = try await load.load(); XCTFail("one-shot reuse accepted") }
        catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .invalidLifecycle) }
        // Success may settle only after a real slot, not merely this receipt;
        // this test intentionally takes the failure retirement path.
        load.revoke()
        XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, UnifiedMemoryCap.minimumLoadKVBytes)
        try await owner.retire(load)
        container = nil // Only passive aliases remain after actual retirement.
        XCTAssertEqual(load.snapshot()?.lifecycle, .retired)
        XCTAssertEqual(ledger.state(for: other.owner), other)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 1234)
        _ = try ledger.replaceCharge(owner: other.owner, expectedRevision: other.revision,
            expectedPolicyEpoch: 0, chargedBytes: 0)
        _ = ledger.retire(other.owner)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
    }

    func testBenchmarkRetirementGateRejectsUnclaimedPendingAndFaultOutcomes() throws {
        XCTAssertThrowsError(try EngineV2BenchmarkSession.requireNativeRetirement(.notClaimed))
        XCTAssertThrowsError(try EngineV2BenchmarkSession.requireNativeRetirement(.pending(.activeOperations)))
        XCTAssertThrowsError(try EngineV2BenchmarkSession.requireNativeRetirement(.retainedFault(code: "test_fault")))
    }

    func testBenchmarkRetirementGateAcceptsActualNoSubmissionReceipt() async throws {
        let root = try fixture()
        let registry = MiMoV26NativeLoadRegistry()
        metadataRegistries.append(registry)
        let lifecycle = try registry.openLifecycle()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        // Explicit synthetic usage oracle; real permit/ledger and actual SDK
        // no-submission receipt. No model is loaded and no M credit is minted.
        let budget = GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        })
        try load.claim(budget: budget, lifecycle: lifecycle, registry: registry)
        let transaction = try XCTUnwrap(load.transaction)
        XCTAssertTrue(registry.retainedTransactionIDs.contains(transaction.id))
        let result = await load.finishFailureAfterUnwind()
        try EngineV2BenchmarkSession.requireNativeRetirement(result)
        guard case .retired(let receipt) = result else { return XCTFail("missing actual retirement") }
        XCTAssertEqual(receipt.transactionID, transaction.id)
        XCTAssertEqual(receipt.construction.completion, .noNativeSubmission)
        XCTAssertNil(receipt.engine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        _ = try registry.closeLifecycle(lifecycle)
    }

    func testActualNativeBenchmarkPublishesOnceAndRequiresConfirmedTeardown() async throws {
        try lane()
        let root = try fixture()
        let registry = MiMoV26NativeLoadRegistry.shared
        let before = Set(registry.retainedTransactionIDs)
        let modelID = "synthetic-native-mimo"
        let hash = try XCTUnwrap(WeightHasher.computeHash(snapshotDir: root, modelID: modelID))
        let loaded = try await EngineV2Factory.loadNativeMiMoBenchmarkSession(
            modelID: modelID, directory: root, verifiedWeightHash: hash,
            operatorReserveBytes: 4 << 30, mtpEnabled: false, kvBackend: "contiguous",
            environment: ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"])
        do {
            let added = Set(registry.retainedTransactionIDs).subtracting(before)
            XCTAssertEqual(added.count, 1)
            let transaction = try XCTUnwrap(added.first.flatMap { registry.transaction($0) })
            XCTAssertEqual(transaction.snapshot().phase, .published)
            XCTAssertNotNil(loaded.session.rawEngine.nativeShutdownExecutionContractID)
            let request = CBv2Request(id: .init(1), promptTokens: [2, 3, 4],
                sampling: .init(temperature: 0), maxTokens: 2, stopTokens: [], prefixCacheEnabled: false)
            let submitted = try await loaded.session.submit(request)
            var tokens: [Int] = []
            var finish: CBv2FinishReason?
            var usage: CBv2Usage?
            for await event in submitted.events {
                switch event {
                case .delta(_, let emitted, _): tokens += emitted
                case .finished(let reason, let value): finish = reason; usage = value
                }
            }
            XCTAssertEqual(finish, .length)
            XCTAssertEqual(tokens.count, 2)
            XCTAssertEqual(usage?.completionTokens, 2)
            guard finish == .length else { throw FixtureError.waitExpired }
            await loaded.session.complete(receiptID: submitted.receiptID)
            XCTAssertGreaterThan(loaded.session.rawEngine.stepCount, 0)
            try await loaded.session.shutdownReportingCompletion()
            XCTAssertEqual(transaction.snapshot().phase, .retired)
            XCTAssertFalse(registry.retainedTransactionIDs.contains(transaction.id))
            try await loaded.session.shutdownReportingCompletion() // same actual retirement is idempotent
            do { _ = try await loaded.session.submit(request); XCTFail("closed native session admitted") }
            catch { guard case EngineV2BenchmarkSession.Failure.closed = error else { throw error } }
        } catch {
            try await loaded.session.shutdownReportingCompletion()
            throw error
        }
    }

    func testRevocationBeforeFactoryNeverRefundsUntilExplicitUnwind() async throws {
        try lane()
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root)), budget = budget()
        let owner = try claim(load, budget: budget)
        let before = try XCTUnwrap(load.snapshot()?.ownerState?.chargedBytes)
        load.revoke()
        XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, before)
        do { _ = try await load.load(); XCTFail("revoked load accepted") } catch {}
        XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, before)
        try await owner.retire(load)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testDescriptorDriftAcrossSuspensionRefusesRealCallerAndRetainsCharge() async throws {
        try lane()
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root)), budget = budget()
        let owner = try claim(load, budget: budget)
        let before = try XCTUnwrap(load.snapshot()?.ownerState?.chargedBytes)
        await Task.yield()
        let url = root.appendingPathComponent("conversion_manifest.json")
        var bytes = try Data(contentsOf: url); bytes.append(10); try bytes.write(to: url)
        do {
            _ = try await owner.load(load, from: root)
            XCTFail("stale native descriptor crossed the actual load caller")
        } catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .changedDescriptor) }
        XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, before)
        load.revoke()
        try await owner.retire(load)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testRealNativeSlotExplicitMTPHasBoundedAdmissionCompleteEOSAndNoDoubleWeightCharge() async throws {
        try lane()
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root)), budget = budget()
        let owner = try claim(load, budget: budget)
        let container = try await owner.load(load, from: root)
        let bundle = try await owner.setup(load) {
            let preparation = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil, environment: [:])
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: "synthetic-native-mimo",
                isVLM: false, modelDirectory: root, container: container, specDecPreparation: preparation)
            // Preparation now reports intent only. Keep the original positive
            // assistant/active/bytes oracles below on the actual built pipeline.
            XCTAssertNil(prepared.assistant)
            XCTAssertFalse(prepared.mtpStatus.active)
            XCTAssertEqual(prepared.assistantBytes, 0, "embedded parameters are already counted in the loaded owner")
            let sizing = await container.sizing(modelPath: root, defaultMaxTokens: 32)
            XCTAssertEqual(sizing.maxContextLength, 128, "synthetic native context; no generic model-ID cap")
            XCTAssertEqual(sizing.auxiliaryWeightBytes, 0)
            let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: root)
            let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: "synthetic-native-mimo",
                modelType: "mimo_v2", isVLM: false, modelDirectory: root, container: container,
                tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1,
                kvBudget: budget, specDecPreparation: preparation, preparedModel: prepared,
                environment: ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"],
                startServingTelemetry: false)
            owner.retain(bundle)
            return bundle
        }
        let ownedEngine = await bundle.bridge.ownedEngine
        let engine = try XCTUnwrap(ownedEngine as? EngineV2)
        XCTAssertNotNil(engine.loopForTesting.mtp?.drafter)
        XCTAssertTrue(bundle.mtpStatus.active)
        XCTAssertGreaterThan(bundle.mtpStatus.assistantBytes, 0)
        if case .bounded? = engine.resolvedMTPAdmission {} else { XCTFail("real assistant lacks bounded admission") }
        let stops = await bundle.bridge.stopTokenIds
        XCTAssertEqual(stops, [1, 13])
        XCTAssertEqual(load.snapshot()?.lifecycle, .setup)
        _ = try await load.sealConstructionForPublication()
        let published = try load.commitPublication { bundle }
        XCTAssertTrue(published === bundle)
        XCTAssertEqual(load.transaction?.snapshot().phase, .published)
        XCTAssertEqual(load.snapshot()?.lifecycle, .retired)
        try await owner.retire(load)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testRealLoadedOwnerKillSwitchProducesNoAssistantAndPagedRefusesBeforeProbe() async throws {
        try lane()
        let root = try fixture(), load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root)), budget = budget()
        let owner = try claim(load, budget: budget)
        let container = try await owner.load(load, from: root)
        let bundle = try await owner.setup(load) {
            let preparation = try MiMoV26ServingLoad.preparation(mode: .on, externalPath: nil,
                environment: ["DARKBLOOM_CBV2_MTP": "0"])
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: "synthetic-native-mimo",
                isVLM: false, modelDirectory: root, container: container, specDecPreparation: preparation)
            XCTAssertNil(prepared.assistant)
            XCTAssertEqual(prepared.mtpStatus.reason, .killSwitchDisabled)
            guard case .nativeMiMo = prepared else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
            let sizing = await container.sizing(modelPath: root, defaultMaxTokens: 32)
            let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: root)
            let epoch = load.transaction?.snapshot().constructionEpoch
            do {
                _ = try await EngineV2SlotFactory.makeProductionBundle(modelId: "synthetic-native-mimo",
                    modelType: "mimo_v2", isVLM: false, modelDirectory: root, container: container,
                    tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1,
                    kvBudget: budget, kvBackendConfig: "paged", specDecPreparation: preparation, preparedModel: prepared)
                XCTFail("unqualified native paging accepted")
            } catch { XCTAssertEqual(error as? MiMoV26ServingLoadError, .unsupportedBackend) }
            XCTAssertEqual(load.transaction?.snapshot().constructionEpoch, epoch)
            XCTAssertEqual(load.snapshot()?.ownerState?.chargedBytes, UnifiedMemoryCap.minimumLoadKVBytes)
            // The refused paged call created no pipeline. Build the one real
            // supported pipeline to retain the original nil-assistant oracle,
            // rather than letting metadata-only preparation pass it vacuously.
            let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: "synthetic-native-mimo",
                modelType: "mimo_v2", isVLM: false, modelDirectory: root, container: container,
                tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1,
                kvBudget: budget, kvBackendConfig: "contiguous", specDecPreparation: preparation, preparedModel: prepared,
                environment: ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"],
                startServingTelemetry: false)
            owner.retain(bundle)
            return bundle
        }
        let raw = await bundle.bridge.ownedEngine
        let engine = try XCTUnwrap(raw as? EngineV2)
        XCTAssertNil(engine.loopForTesting.mtp?.drafter)
        XCTAssertFalse(bundle.hasAssistant)
        load.revoke()
        try await owner.retire(load)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    // F2/F3 methods and every original oracle are retained. Only ownership and
    // preparation observation boundaries migrate to the tracked native API.
    private struct AdmissionTestSlot: Sendable {
        let container: ProviderModelContainer
        let bundle: ProviderEngineBundle
        let engine: EngineV2
        let budget: GlobalKVCacheBudget
        let usage: MiMoAdmissionUsage
        let kinds: [CBv2LayerKind]
        let probe: CBv2NativeKVTypeProbe.Result
        let context: Int
        let load: MiMoV26ServingLoad
        let owner: MiMoServingTestOwner
        func close() async throws {
            try await owner.retire(load)
        }
    }

    private func admissionSlot(float32: Bool, mtp: Bool) async throws -> AdmissionTestSlot {
        try lane()
        let root = try fixture(float32: float32, asymmetric: true)
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        let usage = MiMoAdmissionUsage()
        // Preserve the original explicit logical-admission policy oracle. This
        // zero activation reserve is not production policy or physical proof.
        let budget = GlobalKVCacheBudget(activationReserveBytes: 0, memorySnapshot: usage.read)
        let owner = try claim(load, budget: budget)
        let container = try await owner.load(load, from: root)
        let transaction = try XCTUnwrap(load.transaction)
        let (bundle, engine, kinds, probe, context) = try await owner.setup(load) {
            let preparation = try MiMoV26ServingLoad.preparation(mode: mtp ? .on : .off, externalPath: nil, environment: [:])
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: "native-admission-fixture",
                isVLM: false, modelDirectory: root, container: container, specDecPreparation: preparation)
            guard case .nativeMiMo = prepared else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
            // Retain the independent actual cold native observation. It has no
            // serving engine/assistant and returns only Sendable metadata; raw
            // model/adapter/cache/arrays never escape the protected SDK scope.
            // The actual factory below still independently probes its pipeline.
            let (probe, kinds) = try await transaction.withNativeConstruction { model, scope in
                let binding = try model.makeCBv2Binding(enableMTP: false)
                return (try binding.adapter.probeNativeKVTypes(retaining: scope), binding.adapter.layerKinds)
            }
            let dtype: DType = float32 ? .float32 : .bfloat16
            XCTAssertEqual(probe.layerDTypes, [dtype, dtype])
            XCTAssertEqual(probe.observations.count, 4)
            XCTAssertTrue(probe.observations.allSatisfy { $0.keysDType == dtype && $0.valuesDType == dtype })
            XCTAssertTrue(probe.observations.allSatisfy { $0.keysShape.last == 32 && $0.valuesShape.last == 64 })
            XCTAssertEqual(kinds.count, 2)
            XCTAssertEqual(kinds.map(\.headDim), [32, 32])
            XCTAssertEqual(kinds.map(\.valueHeadDim), [64, 64])
            XCTAssertEqual(kinds.map(\.kvHeads), [1, 1])
            XCTAssertEqual(kinds[0].attention, .full)
            XCTAssertEqual(kinds[1].attention, .slidingWindow(8))
            let sizing = await container.sizing(modelPath: root, defaultMaxTokens: 32)
            let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: root)
            let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: "native-admission-fixture",
                modelType: "mimo_v2", isVLM: false, modelDirectory: root, container: container,
                tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2,
                kvBudget: budget, specDecPreparation: preparation, preparedModel: prepared,
                environment: ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"],
                startServingTelemetry: false)
            owner.retain(bundle)
            let raw = await bundle.bridge.ownedEngine
            let engine = try XCTUnwrap(raw as? EngineV2)
            XCTAssertEqual(bundle.assistantBytes, 0, "complete loaded weights already contain the embedded heads")
            if mtp {
                XCTAssertTrue(CBv2MTPConfig.envEnabled)
                guard case .bounded? = engine.resolvedMTPAdmission else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
                XCTAssertGreaterThan(engine.resolvedFixedBytesPerRequest, 0)
            } else { XCTAssertEqual(engine.resolvedFixedBytesPerRequest, 0) }
            return (bundle, engine, kinds, probe, sizing.maxContextLength)
        }
        _ = try await load.sealConstructionForPublication()
        let slot = try load.commitPublication {
            AdmissionTestSlot(container: container, bundle: bundle, engine: engine, budget: budget,
                usage: usage, kinds: kinds, probe: probe, context: context, load: load, owner: owner)
        }
        XCTAssertEqual(transaction.snapshot().phase, .published)
        // Subsequent tight-capacity checks concern real owner C/refund logic,
        // not physical peak. Do not use this oracle during native loading.
        usage.useControlledAdmissionUsage()
        return slot
    }

    private func waitForTerminal(_ gate: MiMoAdmissionTerminalGate) async throws -> CBv2Usage {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while gate.usage == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        return try XCTUnwrap(gate.usage, "actual native request did not reach its terminal gate")
    }

    private func assertNoErrors(_ stream: AsyncStream<GenerationEvent>, expectedCompletion: Int? = nil) async {
        var reportedCompletion: Int?
        for await event in stream {
            switch event {
            case .error(let value): XCTFail(value)
            case .info(_, let count, _, _): reportedCompletion = count
            case .terminal(_, _, _, let count): reportedCompletion = count
            case .chunk: break
            }
        }
        if let expectedCompletion { XCTAssertEqual(reportedCompletion, expectedCompletion) }
    }

    func testAdmissionGeometrySeparatesAsymmetricWidthsOwnersAndConservativeMixedTypes() throws {
        let full = CBv2LayerKind(attention: .full, headDim: 128, valueHeadDim: 192, kvHeads: 2, queryHeads: 4)
        let window = CBv2LayerKind(attention: .slidingWindow(257), headDim: 128, valueHeadDim: 192, kvHeads: 2, queryHeads: 4)
        var borrower = window; borrower.sharesKVWithLayer = 1
        let kinds = [full, window, borrower]
        let bf16 = try MiMoV26AdmissionGeometry(layerKinds: kinds,
            probedDTypes: [.bfloat16, .bfloat16, .bfloat16], maximumContextTokens: 1_048_576)
        XCTAssertEqual(bf16.elementBytes, 2)
        XCTAssertEqual(bf16.fullKVBytesPerToken, 1280)
        XCTAssertEqual(bf16.targetWindowLogicalBytes, 328_960)
        for n in [1, 256, 257, 258, 1_048_576] {
            XCTAssertEqual(try bf16.logicalTargetBytes(positiveTokens: n), 1280*n + 328_960)
        }
        XCTAssertEqual(bf16.internalAdmissionConfig.fixedBytesPerRequest, 0)
        XCTAssertEqual(try bf16.sharedFixedRequestBytes(resolvedNonTargetFixedBytes: 73), 329_033)
        let fp16 = try MiMoV26AdmissionGeometry(layerKinds: kinds,
            probedDTypes: [.float16, .float16, .float16], maximumContextTokens: 1024)
        XCTAssertEqual(fp16.elementBytes, 2)
        XCTAssertEqual(fp16.targetWindowLogicalBytes, bf16.targetWindowLogicalBytes)
        // Pure component arithmetic, not a serving-load or native-run claim.
        // The strict root serving contract is BF16-only; the geometry component
        // must still conservatively price FP32 and mixed dtype observations.
        let tables: [[DType]] = [[.bfloat16, .float32, .float32], [.bfloat16, .float16, .float16], [.float32, .float32, .float32]]
        for types in tables {
            let value = try MiMoV26AdmissionGeometry(layerKinds: kinds, probedDTypes: types, maximumContextTokens: 1024)
            XCTAssertEqual(value.elementBytes, 4)
            XCTAssertEqual(value.fullKVBytesPerToken, 2560)
            XCTAssertEqual(value.targetWindowLogicalBytes, 657_920)
            XCTAssertEqual(value.internalAdmissionConfig.fixedBytesPerRequest, 0)
            XCTAssertEqual(try value.sharedFixedRequestBytes(resolvedNonTargetFixedBytes: 73), 657_993)
            let actualCost = 2560 * 258 + 657_920
            let admission = AdmissionV2(layerKinds: kinds, bytesCapacity: actualCost,
                config: value.internalAdmissionConfig)
            for n in [1, 256, 257, 258, 1024] {
                let expected = 2560 * n + 657_920
                XCTAssertEqual(try value.logicalTargetBytes(positiveTokens: n), expected)
                XCTAssertEqual(admission.allocatedBytes(forTokens: n), expected)
            }
            XCTAssertGreaterThan(admission.admissibleBytesCapacity, actualCost / 2)
            XCTAssertLessThan(admission.admissibleBytesCapacity, actualCost)
            XCTAssertFalse(admission.canEverFit(promptTokens: 257, maxTokens: 1))
            XCTAssertEqual(admission.bytesReserved, 0)
        }
    }

    func testAdmissionGeometryFailsClosedOnProbeGeometryContextAndFixedOverflow() throws {
        let full = CBv2LayerKind(attention: .full, headDim: 128, valueHeadDim: 192, kvHeads: 2, queryHeads: 4)
        let window = CBv2LayerKind(attention: .slidingWindow(8), headDim: 32, valueHeadDim: 64, kvHeads: 1, queryHeads: 2)
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [full], probedDTypes: [], maximumContextTokens: 128))
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [full], probedDTypes: [.uint32], maximumContextTokens: 128))
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [full], probedDTypes: [.float32], maximumContextTokens: 0))
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [full], probedDTypes: [.float32], maximumContextTokens: Int.max))
        var hugeKey = full; hugeKey.headDim = Int.max
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [hugeKey], probedDTypes: [.float32], maximumContextTokens: 1))
        var hugeValue = full; hugeValue.valueHeadDim = Int.max
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [hugeValue], probedDTypes: [.float32], maximumContextTokens: 1))
        var hugeWindow = window; hugeWindow.attention = .slidingWindow(Int.max)
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [hugeWindow], probedDTypes: [.float32], maximumContextTokens: 1))
        var selfBorrower = window; selfBorrower.sharesKVWithLayer = 1
        XCTAssertThrowsError(try MiMoV26AdmissionGeometry(layerKinds: [full, selfBorrower],
            probedDTypes: [.bfloat16, .bfloat16], maximumContextTokens: 128))
        let value = try MiMoV26AdmissionGeometry(layerKinds: [full, window], probedDTypes: [.bfloat16, .bfloat16], maximumContextTokens: 128)
        XCTAssertThrowsError(try value.logicalTargetBytes(positiveTokens: 0))
        XCTAssertThrowsError(try value.logicalTargetBytes(positiveTokens: -1))
        XCTAssertThrowsError(try value.logicalTargetBytes(positiveTokens: 129))
        XCTAssertThrowsError(try value.sharedFixedRequestBytes(resolvedNonTargetFixedBytes: Int.max))
        XCTAssertThrowsError(try value.sharedFixedRequestBytes(resolvedNonTargetFixedBytes: -1))
    }

    private func exerciseRealTargetAdmission(float32: Bool) async throws {
        let slot = try await admissionSlot(float32: float32, mtp: false)
        do {
            let width = float32 ? 4 : 2
            let rate = (32 + 64) * width // independent known tiny asymmetric oracle
            let ring = 8 * rate
            XCTAssertEqual(slot.context, 128)
            XCTAssertEqual(slot.engine.admissionForTesting.fixedBytesPerRequest, 0,
                "Do not put target rings into internal fixed state a second time")
            XCTAssertEqual(slot.engine.admissionForTesting.allocatedBytes(forTokens: 0), 0)
            for prompt in [1, 7, 8, 9, 127] {
                let completion = min(12, 128 - prompt), total = prompt + completion
                let expected = rate * total + ring
                XCTAssertEqual(slot.engine.admissionForTesting.allocatedBytes(forTokens: total), expected)
                let shared = await slot.bundle.bridge.requestReservationBytes(tokenCount: total)
                XCTAssertEqual(shared, expected)
                let request = ChatCompletionRequest(model: "native-admission-fixture", messages: [],
                    temperature: 0, max_tokens: completion, logit_bias: ["12": 100])
                let stream = await slot.bundle.bridge.submitTokenized(
                    promptTokens: Array(repeating: 12, count: prompt), request: request,
                    requestId: "wrap-\(prompt)", cacheEnabled: false)
                await assertNoErrors(stream, expectedCompletion: completion)
                try await waitForSharedCharge(slot.budget, expected: 0)
                XCTAssertEqual(slot.engine.admissionForTesting.bytesReserved, 0)
            }
            XCTAssertGreaterThan(slot.engine.stepCount, 0, "must execute the actual native target")
            let negative = await slot.bundle.bridge.requestReservationBytes(tokenCount: -1)
            let overflow = await slot.bundle.bridge.requestReservationBytes(tokenCount: Int.max)
            XCTAssertNil(negative); XCTAssertNil(overflow)
            // The configured context edge is a real bridge refusal, not an
            // enormous tensor/array allocation or a changed model cap.
            let outside = await slot.bundle.bridge.submitTokenized(promptTokens: Array(repeating: 12, count: 129),
                request: .init(model: "native-admission-fixture", messages: [], max_tokens: 1),
                requestId: "over-context", cacheEnabled: false)
            var sawError = false
            for await event in outside { if case .error = event { sawError = true } }
            XCTAssertTrue(sawError)
            try await waitForSharedCharge(slot.budget, expected: 0)
        } catch { try await slot.close(); throw error }
        try await slot.close()
    }

    private func waitForSharedCharge(_ budget: GlobalKVCacheBudget, expected: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while budget.processLedger.snapshot().chargedBytes != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, expected)
        guard budget.processLedger.snapshot().chargedBytes == expected else { throw FixtureError.waitExpired }
    }

    func testRealBF16AsymmetricFactoryAdmissionAndBridgeAcrossWindowAndContext() async throws {
        try await exerciseRealTargetAdmission(float32: false)
    }

    /// Coverage correction: former positive FP32 factory/bridge cases could
    /// never reach their native assertions under the BF16-only load contract.
    /// Keep real preflight refusal explicit; pure FP32 admission math above is
    /// not evidence that an FP32 serving model was loaded or executed.
    private func assertFP32PreflightRefusesBeforeOwnership(asymmetric: Bool) throws {
        let root = try fixture(float32: true, asymmetric: asymmetric)
        XCTAssertTrue(nativeOwners.isEmpty)
        XCTAssertTrue(metadataRegistries.isEmpty)
        var inspected: MiMoV26ServingLoad?
        do {
            inspected = try MiMoV26ServingLoad.inspect(directory: root)
            XCTFail("FP32 must be refused before a serving load can be claimed")
        } catch {
            XCTAssertEqual(error as? MiMoV26LoadFootprintError, .unsupportedProfile)
        }
        XCTAssertNil(inspected)
        XCTAssertTrue(nativeOwners.isEmpty, "Preflight must not create a native owner")
        XCTAssertTrue(metadataRegistries.isEmpty, "Preflight must not create a load registry")
        // No claim, native load, bridge, engine or capacity submission is reached.
    }

    func testFP32ProfileRefusesBeforeNativeServingOwnership() throws {
        try assertFP32PreflightRefusesBeforeOwnership(asymmetric: false)
    }

    func testFP32AsymmetricProfileRefusesBeforeNativeServingOwnership() throws {
        try assertFP32PreflightRefusesBeforeOwnership(asymmetric: true)
    }

    private func exerciseRealSharedRingCharge(mtp: Bool) async throws {
        #if DEBUG
        let slot = try await admissionSlot(float32: false, mtp: mtp)
        let gate = MiMoAdmissionTerminalGate()
        defer { gate.open() }
        do {
            let rate = (32 + 64) * 2, ring = 8 * rate
            let fixed = slot.engine.resolvedFixedBytesPerRequest
            XCTAssertEqual(slot.engine.admissionForTesting.fixedBytesPerRequest, fixed)
            for n in [1, 7, 8, 9, 128] {
                let shared = await slot.bundle.bridge.requestReservationBytes(tokenCount: n)
                XCTAssertEqual(shared, rate*n + ring + fixed)
                XCTAssertEqual(slot.engine.admissionForTesting.allocatedBytes(forTokens: n), rate*n + ring + fixed)
            }
            let prompt = 3, completion = 4, needed = rate*(prompt+completion) + ring + fixed
            let otherBytes: UInt64 = 73
            let ledger = slot.budget.processLedger
            let epoch = ledger.policySnapshot().epoch + 1
            XCTAssertTrue(ledger.updatePolicy(.init(epoch: epoch, capBytes: UInt64(needed) + otherBytes, reserveBytes: 0)))
            let otherAccepted = await slot.budget.reserveBytes(requestID: "unrelated-native-owner", bytes: otherBytes)
            XCTAssertTrue(otherAccepted)
            await slot.bundle.bridge._testInstallCancelledSettlementHooks(
                beforeNativeTerminal: { await gate.enter($0) }, onSettlementWait: {})
            // Real factory + native target + real bridge submit. Hold only the
            // existing terminal-publication hook after native work has finished;
            // do not replace the engine, sampler, reservation or model success.
            let request = ChatCompletionRequest(model: "native-admission-fixture", messages: [],
                temperature: 0, max_tokens: completion)
            let stream = await slot.bundle.bridge.submitTokenized(promptTokens: Array(repeating: 12, count: prompt),
                request: request, requestId: "held-native", cacheEnabled: false)
            let usage = try await waitForTerminal(gate)
            XCTAssertEqual(usage.promptTokens, prompt)
            XCTAssertGreaterThan(usage.completionTokens, 0)
            XCTAssertGreaterThan(slot.engine.stepCount, 0)
            XCTAssertEqual(ledger.snapshot().chargedBytes, UInt64(needed) + otherBytes)
            XCTAssertEqual(ledger.snapshot().materializedBytes, 0, "Logical shared reservation is not fabricated M credit")
            let heldIDs = await slot.budget.reservationIDsForTesting()
            XCTAssertEqual(Set(heldIDs), Set(["held-native", "unrelated-native-owner"]))
            let priorSteps = slot.engine.stepCount
            let refused = await slot.bundle.bridge.submitTokenized(promptTokens: [12], request: request,
                requestId: "too-tight-native", cacheEnabled: false)
            var errors: [String] = []
            for await event in refused { if case .error(let message) = event { errors.append(message) } }
            XCTAssertTrue(errors.contains { $0.contains("token_budget_exhausted") })
            XCTAssertEqual(slot.engine.stepCount, priorSteps)
            XCTAssertEqual(ledger.snapshot().chargedBytes, UInt64(needed) + otherBytes)
            gate.open()
            await assertNoErrors(stream)
            try await waitForSharedCharge(slot.budget, expected: otherBytes)
            let remaining = await slot.budget.reservationIDsForTesting()
            XCTAssertEqual(remaining, ["unrelated-native-owner"])
            await slot.budget.release(requestID: "unrelated-native-owner")
            try await waitForSharedCharge(slot.budget, expected: 0)
            XCTAssertEqual(slot.engine.admissionForTesting.bytesReserved, 0)
        } catch {
            gate.open()
            try await slot.close()
            await slot.budget.release(requestID: "unrelated-native-owner")
            throw error
        }
        try await slot.close()
        #else
        throw FixtureError.debugSeamsRequired
        #endif
    }

    func testRealBridgeSharedTargetRingsAndUnrelatedOwnerRetireWithMTPOff() async throws {
        try await exerciseRealSharedRingCharge(mtp: false)
    }

    func testRealBridgeSharedTargetRingsAndBoundedMTPFixedStateAreChargedExactlyOnce() async throws {
        try await exerciseRealSharedRingCharge(mtp: true)
    }

    func testRealBridgeCancelBeforeStepReturnsOnlyItsSharedRingCharge() async throws {
        #if DEBUG
        let slot = try await admissionSlot(float32: false, mtp: false)
        do {
            let otherAccepted = await slot.budget.reserveBytes(requestID: "cancel-other", bytes: 73)
            XCTAssertTrue(otherAccepted)
            slot.engine.loopForTesting.onEngineQueueSync {
                slot.engine.loopForTesting.suspendStepExecutionAtCountForTesting = 0
            }
            let expected = (32 + 64) * 2 * (3 + 4 + 8)
            let stream = await slot.bundle.bridge.submitTokenized(promptTokens: [12, 12, 12],
                request: .init(model: "native-admission-fixture", messages: [], temperature: 0, max_tokens: 4),
                requestId: "cancel-ring", cacheEnabled: false)
            let joined = await slot.bundle.bridge.submitTokenized(promptTokens: [12, 12, 12],
                request: .init(model: "native-admission-fixture", messages: [], temperature: 0, max_tokens: 4),
                requestId: "joined-ring", cacheEnabled: false)
            XCTAssertEqual(slot.budget.processLedger.snapshot().chargedBytes, UInt64(2 * expected + 73),
                "Each real admitted request owns its own target rings")
            XCTAssertEqual(slot.engine.stepCount, 0)
            let mappedCancelID = await slot.bundle.bridge._testEngineRequestId(for: "cancel-ring")
            let mappedJoinedID = await slot.bundle.bridge._testEngineRequestId(for: "joined-ring")
            let cancelID = try XCTUnwrap(mappedCancelID)
            let joinedID = try XCTUnwrap(mappedJoinedID)
            slot.engine.loopForTesting.onEngineQueueSync {
                let loop = slot.engine.loopForTesting
                XCTAssertEqual(loop.stepCount, 0)
                XCTAssertNotNil(loop.scheduler.record(for: cancelID))
                XCTAssertNotNil(loop.scheduler.record(for: joinedID))
            }
            await slot.bundle.bridge.cancel(requestId: "cancel-ring")
            // Gate zero precedes cancellation processing. Allow exactly one
            // boundary so the confirmed enqueued row can retire, while keeping
            // the joined request from reaching its native terminal.
            slot.engine.loopForTesting.onEngineQueueSync {
                slot.engine.loopForTesting.suspendStepExecutionAtCountForTesting = 1
            }
            for await _ in stream {} // Cancellation is a typed terminal, not a success claim.
            try await waitForSharedCharge(slot.budget, expected: UInt64(expected + 73))
            let joinedIDs = await slot.budget.reservationIDsForTesting()
            XCTAssertEqual(Set(joinedIDs), Set(["joined-ring", "cancel-other"]))
            slot.engine.loopForTesting.onEngineQueueSync {
                let loop = slot.engine.loopForTesting
                XCTAssertNil(loop.scheduler.record(for: cancelID))
                XCTAssertNotNil(loop.scheduler.record(for: joinedID))
                XCTAssertLessThanOrEqual(loop.stepCount, 1)
                loop.suspendStepExecutionAtCountForTesting = nil
            }
            await assertNoErrors(joined)
            try await waitForSharedCharge(slot.budget, expected: 73)
            let remaining = await slot.budget.reservationIDsForTesting()
            XCTAssertEqual(remaining, ["cancel-other"])
            await slot.budget.release(requestID: "cancel-other")
            try await waitForSharedCharge(slot.budget, expected: 0)
        } catch {
            slot.engine.loopForTesting.onEngineQueueSync {
                slot.engine.loopForTesting.suspendStepExecutionAtCountForTesting = nil
            }
            await slot.bundle.bridge.cancel(requestId: "cancel-ring")
            await slot.bundle.bridge.cancel(requestId: "joined-ring")
            try await slot.close()
            await slot.budget.release(requestID: "cancel-other")
            throw error
        }
        try await slot.close()
        #else
        throw FixtureError.debugSeamsRequired
        #endif
    }
}

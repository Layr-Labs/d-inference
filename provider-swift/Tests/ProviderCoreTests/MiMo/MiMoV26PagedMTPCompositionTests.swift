import Foundation
import MLXLMServer
import ProviderCoreFoundation
import XCTest
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
@_spi(Benchmarking) @testable import ProviderCore

/// Genuine ordinary provider factory/bridge + real GlobalKVCacheBudget.
/// Requires a separately prepared strict <=128MiB provider-recognized fixture;
/// an SDK-only provenance marker is NOT accepted as provider authorization.
final class MiMoV26PagedMTPCompositionTests: XCTestCase {
    private enum Failure: Error { case fixture, completion }
    private let modelID = "native-paged-mtp-fixture"
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        for registry in registries where !registry.retainedTransactionIDs.isEmpty {
            _ = Unmanaged.passRetained(registry) // preserve actual unfinished ownership
        }
        registries = []; super.tearDown()
    }
    private struct Loaded {
        let load: MiMoV26ServingLoad
        let transaction: MiMoV26NativeLoadTransaction
        let registry: MiMoV26NativeLoadRegistry
        let budget: GlobalKVCacheBudget
        let bundle: ProviderEngineBundle
        let engine: EngineV2
    }

    private func loaded(mtp: Bool) async throws -> Loaded {
        let env = ProcessInfo.processInfo.environment
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_PAGED_MTP_PROVIDER_TESTS", environment: env)
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS", environment: env)
        let path = try XCTUnwrap(env["MIMO_V26_PAGED_MTP_PROVIDER_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath: path)
        let bytes = try MiMoV26ServingLoad.readMetadata(root.appendingPathComponent("config.json"), limit: 1 << 20).bytes
        let config = try JSONDecoder().decode(MiMoV26Configuration.self, from: bytes)
        let scheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2, environment: [:])
        let queryBound = max(scheduler.maxBatchedTokensPerStep,
            max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0))
        guard config.hiddenSize <= 64, config.numHiddenLayers <= 4,
              config.numNextnPredictLayers == 3, config.vocabularySize >= 32,
              config.maxPositionEmbeddings >= queryBound else { throw Failure.fixture }
        for index in 0..<config.numHiddenLayers {
            let geometry = try config.attentionGeometry(at: index)
            guard geometry.headDim == 192, geometry.valueHeadDim == 128,
                  geometry.queryHeads == 64, [4, 8].contains(geometry.keyValueHeads) else { throw Failure.fixture }
        }
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        guard load.plan.bundlePlan.tensorBytes <= 128 << 20 else { throw Failure.fixture }
        let registry = MiMoV26NativeLoadRegistry(); registries.append(registry)
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let container = try await load.load()
        let transaction = try XCTUnwrap(load.transaction)
        let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: root)
        let sizing = await container.sizing(modelPath: root, defaultMaxTokens: 32)
        let environment = ["DARKBLOOM_MIMO_NATIVE_PAGED_TARGET": "1",
            "DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_MIMO_COMPLETE_PREFIX": "0",
            "DARKBLOOM_CBV2_MTP": "1"]
        let intent = try MiMoV26ServingLoad.preparation(mode: mtp ? .on : .off,
            externalPath: nil, environment: environment)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: modelID,
            isVLM: false, modelDirectory: root, container: container, specDecPreparation: intent)
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: modelID, modelType: "mimo_v2",
            isVLM: false, modelDirectory: root, container: container, tokenizer: tokenizer,
            sizing: sizing, kvBytesCapacity: 1 << 30, maxConcurrentRequests: 2,
            kvBudget: budget, kvBackendConfig: "paged", weightHash: nil,
            specDecPreparation: intent, preparedModel: prepared, environment: environment,
            startServingTelemetry: false)
        let owned = await bundle.bridge.ownedEngine
        let engine = try XCTUnwrap(owned as? EngineV2)
        XCTAssertNil(engine.nativeCompletionFault); XCTAssertNil(engine.pagedAttentionWorkInactiveReason)
        XCTAssertNil(engine.completePrefixCache)
        XCTAssertEqual(engine.mtpMetricsSnapshot()?.active == true, mtp)
        XCTAssertFalse(transaction.ownsNativePagedRequestCharge(engine: engine, bridge: bundle.bridge, budget: budget))
        _ = try await load.sealConstructionForPublication()
        try load.commitPublication {}
        XCTAssertTrue(transaction.ownsNativePagedRequestCharge(engine: engine, bridge: bundle.bridge, budget: budget))
        let foreign = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        XCTAssertFalse(transaction.ownsNativePagedRequestCharge(engine: engine, bridge: bundle.bridge, budget: foreign))
        XCTAssertFalse(transaction.ownsNativeCompletePrefixRequestCharge(engine: engine, bridge: bundle.bridge, budget: budget))
        return .init(load: load, transaction: transaction, registry: registry,
            budget: budget, bundle: bundle, engine: engine)
    }

    private func retire(_ value: Loaded) async throws {
        let id = try XCTUnwrap(value.engine.nativeShutdownExecutionContractID)
        do {
            _ = try await value.bundle.bridge.shutdownNativeConstruction(
                expectedEngine: value.engine, executionContractID: id)
        } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            let snapshot = await value.bundle.bridge.nativeRetirementTaskSnapshot()
            guard snapshot.sdkQuiescence?.executionContractID == id else { throw Failure.completion }
            for task in snapshot.tasks { await task.value }
        }
        guard case .retired(let receipt) = await value.load.finishFailureAfterUnwind() else { throw Failure.completion }
        XCTAssertEqual(receipt.engine?.executionContractID, id)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(value.registry.retainedTransactionIDs.isEmpty)
    }

    func testActualProviderPagedMTPUsesOneProcessOwnerAndGenuineRetirement() async throws {
        let value = try await loaded(mtp: true)
        let before = try XCTUnwrap(value.engine.mtpMetricsSnapshot())
        let requestID = "paged-real-mtp"
        let events = await value.bundle.bridge.submitTokenized(
            promptTokens: (0..<145).map { 1 + ($0 * 7) % 29 },
            request: .init(model: modelID, messages: [], temperature: 0, max_tokens: 32),
            requestId: requestID, cacheScope: "synthetic-paged-test")
        var terminals = 0
        for await event in events {
            let shared = await value.budget.reservationIDsForTesting()
            XCTAssertFalse(shared.contains(requestID), "same actual Admission must not also reserve bridge R")
            switch event {
            case .info: terminals += 1
            case .error(let message): XCTFail(message)
            case .terminal: XCTFail("unexpected native terminal refusal")
            default: break
            }
        }
        XCTAssertEqual(terminals, 1)
        let pumps = await value.bundle.bridge.pumpTasks
        for task in pumps.values { await task.value }
        let transferred = await value.bundle.bridge.nativeTransferredRetirementTasks
        for task in transferred.values { await task.value }
        let after = try XCTUnwrap(value.engine.mtpMetricsSnapshot())
        XCTAssertGreaterThan(after.draftedTokens - before.draftedTokens, 0)
        XCTAssertGreaterThan(after.serialVerificationRounds - before.serialVerificationRounds, 0)
        XCTAssertEqual(after.rectangularVerificationRounds, 0)
        XCTAssertTrue(value.transaction.ownsNativePagedRequestCharge(
            engine: value.engine, bridge: value.bundle.bridge, budget: value.budget))
        try await retire(value)
    }

    func testDefaultTargetOnlyPagedFactoryStillHasNoAssistant() async throws {
        let value = try await loaded(mtp: false)
        XCTAssertNil(value.engine.mtpMetricsSnapshot())
        try await retire(value)
    }
}

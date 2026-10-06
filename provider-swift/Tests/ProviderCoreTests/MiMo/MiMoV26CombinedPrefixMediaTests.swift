import Foundation
import MLXLMServer
import ProviderCoreFoundation
import XCTest
@testable import MLXLMCommon
@testable import MLXLLM
@testable import MLXVLM
@_spi(Benchmarking) @testable import ProviderCore

/// UNRUN. Actual ordinary factory, encrypted ephemeral store, same real global
/// ledger, bridge and managed media consumer lease. Explicit small target
/// fixture only; audio still authenticates the actual selected sidecar.
final class MiMoV26CombinedPrefixMediaTests: XCTestCase {
    private enum Failure: Error { case requiredInput, completion }
    private let modelID = "combined-native-mimo-fixture"
    private struct Loaded: Sendable {
        let root: URL
        let load: MiMoV26ServingLoad
        let transaction: MiMoV26NativeLoadTransaction
        let registry: MiMoV26NativeLoadRegistry
        let budget: GlobalKVCacheBudget
        let container: ProviderModelContainer
        let bundle: ProviderEngineBundle
        let engine: EngineV2
        let tokenizer: TokenizerHandle
        let store: SSDHybridCheckpointStore
    }
    private var registries: [MiMoV26NativeLoadRegistry] = []
    override func tearDown() {
        for registry in registries where !registry.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(registry) }
        registries = []; super.tearDown()
    }
    private func policy() throws -> MiMoV26ServingLoad.DecodedAudioPolicy {
        let limits = MiMoV26MultimodalLimits(maximumMedia:4,maximumVideoFrames:4,maximumPromptTokens:2048,
            maximumMetadataBytes:1 << 20,maximumMetadataNodes:10000,maximumMetadataDepth:32,
            pixels:.init(maximumInputElements:100000,maximumOutputElements:100000,maximumWorkingBytes:1 << 20),
            vision:.init(maximumPatches:256,maximumAttentionScoreElements:131072),
            audio:.init(maximumClips:2,maximumChannels:1,maximumSampleRate:24000,
                maximumInputSamples:48000,maximumResampledSamples:48000,maximumResampleCoefficients:100000,
                maximumMelFrames:256,maximumSegments:4,maximumPaddedMelFrames:256,
                maximumWorkingElements:64_000_000,frontendFrameBlockSize:8,rvqTileFrames:8),
            audioPatch:.init(maximumClips:2,maximumFrames:256,maximumPatches:64,maximumWorkingElements:16_000_000))
        return try .init(media:.init(limits:limits,maximumReservationBytes:8 << 30,
            additionalSystemReserveBytes:4 << 30),maximumSidecarReservationBytes:4 << 30,
            additionalSystemReserveBytes:4 << 30)
    }

    private func loaded(audio: Bool, mtp: Bool) async throws -> Loaded {
        let flags = ProcessInfo.processInfo.environment
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_SERIAL_NATIVE_TESTS", environment: flags)
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS", environment: flags)
        let path = try XCTUnwrap(flags["MIMO_V26_MANAGED_AUDIO_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath: path)
        let data = try MiMoV26ServingLoad.readMetadata(root.appendingPathComponent("config.json"), limit: 1 << 20).bytes
        let config = try JSONDecoder().decode(MiMoV26Configuration.self, from: data)
        guard config.hiddenSize <= 64, config.numHiddenLayers <= 4,
              config.vocabularySize > 151674, config.maxPositionEmbeddings >= 1041 else { throw Failure.requiredInput }
        let policy = try policy()
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root,
            decodedMediaPolicy: audio ? nil : policy.media, decodedAudioPolicy: audio ? policy : nil))
        guard load.plan.bundlePlan.tensorBytes <= 128 << 20 else { throw Failure.requiredInput }
        let registry = MiMoV26NativeLoadRegistry(); registries.append(registry)
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let container = try await load.load()
        let transaction = try XCTUnwrap(load.transaction)
        let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: root)
        let sizing = await container.sizing(modelPath: root, defaultMaxTokens: 16)
        let cacheRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("combined-mimo-prefix-" + UUID().uuidString)
        let environment = ["DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_MIMO_COMPLETE_PREFIX": "1",
            "DARKBLOOM_PREFIX_CACHE_MEMORY": "0", "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: cacheRoot.path]
        XCTAssertTrue(SSDPrefixCacheFactory.forceEphemeralKey(environment: environment),
                      "this selector must never open production credentials or persistent keys")
        guard bindRuntimeMetallibForMLX() != nil else { throw Failure.requiredInput }
        let weightHash = try XCTUnwrap(WeightHasher.computeHash(snapshotDir: root, modelID: modelID))
        let intent = try MiMoV26ServingLoad.preparation(mode: mtp ? .on : .off,
            externalPath: nil, environment: environment)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(modelId: modelID,
            isVLM: false, modelDirectory: root, container: container, specDecPreparation: intent)
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: modelID, modelType: "mimo_v2",
            isVLM: false, modelDirectory: root, container: container, tokenizer: tokenizer,
            sizing: sizing, kvBytesCapacity: 2 << 30, maxConcurrentRequests: 1,
            kvBudget: budget, kvBackendConfig: "contiguous", weightHash: weightHash, specDecPreparation: intent,
            preparedModel: prepared, environment: environment, startServingTelemetry: false)
        let owned = await bundle.bridge.ownedEngine
        let engine = try XCTUnwrap(owned as? EngineV2)
        let store = try XCTUnwrap(engine.completePrefixCache as? SSDHybridCheckpointStore)
        XCTAssertTrue(store.kvBudget === budget)
        XCTAssertTrue(engine.usesProcessMemoryOwner)
        XCTAssertFalse(transaction.ownsNativeCompletePrefixRequestCharge(engine: engine, bridge: bundle.bridge, budget: budget))
        _ = try await load.sealConstructionForPublication()
        try load.commitPublication {}
        XCTAssertTrue(transaction.ownsNativeCompletePrefixRequestCharge(engine: engine, bridge: bundle.bridge, budget: budget))
        return .init(root: root, load: load, transaction: transaction, registry: registry,
            budget: budget, container: container, bundle: bundle, engine: engine, tokenizer: tokenizer, store: store)
    }
    private func joinRequestConsumers(_ value: Loaded) async {
        let pumps = await value.bundle.bridge.pumpTasks
        for task in pumps.values { await task.value }
        let transferred = await value.bundle.bridge.nativeTransferredRetirementTasks
        for task in transferred.values { await task.value }
        await value.store.waitForWritesForTesting()
    }
    private func text(_ value: Loaded, id: String) async throws -> (String, Int) {
        let usage = EngineV2RequestUsageSignal()
        // Exactly one request at a time; join its actual pump/retirement before
        // taking the endpoint. These are real per-request counter intervals,
        // not a new fabricated usage signal or a process-wide counter.
        let beforeMTP = value.engine.mtpMetricsSnapshot()
        let events = await value.bundle.bridge.submitTokenized(
            promptTokens: (0..<1025).map { 20 + ($0 % 9) },
            request: .init(model: modelID, messages: [], temperature: 0, max_tokens: 16),
            requestId: id, cacheScope: "joint-fixture-tenant", usageSignal: usage)
        var output = "", terminals = 0
        for await event in events {
            let reservations = await value.budget.reservationIDsForTesting()
            XCTAssertFalse(reservations.contains(id), "same engine Admission must not also acquire bridge R")
            switch event {
            case .chunk(let part): output += part
            case .info: terminals += 1
            case .error(let message): XCTFail(message)
            case .terminal: XCTFail("unexpected native failure")
            }
        }
        XCTAssertEqual(terminals, 1)
        await joinRequestConsumers(value)
        let afterMTP = value.engine.mtpMetricsSnapshot()
        if let beforeMTP {
            let afterMTP = try XCTUnwrap(afterMTP)
            XCTAssertTrue(beforeMTP.active); XCTAssertTrue(afterMTP.active)
            XCTAssertEqual(afterMTP.verificationMode, .serialTarget)
            let rounds = afterMTP.rounds-beforeMTP.rounds
            XCTAssertGreaterThan(rounds, 0, "\(id): this request must draft and verify")
            XCTAssertGreaterThan(afterMTP.draftedTokens-beforeMTP.draftedTokens, 0)
            XCTAssertEqual(afterMTP.serialVerificationRounds-beforeMTP.serialVerificationRounds, rounds)
            XCTAssertEqual(afterMTP.rectangularVerificationRounds-beforeMTP.rectangularVerificationRounds, 0)
            // Do not constrain acceptedTokens: trained tiny-fixture proposals
            // need not match a target for this genuine engagement witness.
        } else { XCTAssertNil(afterMTP) }
        return (output, usage.prefixCachePrefillTokensSaved ?? 0)
    }
    private func media(_ value: Loaded, audio: Bool) async throws {
        let before = value.store.stats().filesWritten
        let beforeMTP = value.engine.mtpMetricsSnapshot()
        let lease = NativeLocalConsumerLease()
        let acquired = MultiModelBatchSchedulerEngine.AcquiredModel(tokenizer: value.tokenizer,
            releaseToken: .init(release: { _ in }, modelId: modelID, nativeConsumerLease: lease),
            modelType: "mimo_v2", container: value.container.autoregressive, isVLM: false,
            engineV2Bridge: value.bundle.bridge)
        let parts: [MiMoV26MultimodalContent]
        if audio {
            let pcm = try MiMoV26DecodedPCM(samples: (0..<2400).map { sin(Float($0) * 0.02) * 0.05 },
                descriptor: .init(sourceIdentity: "joint-owned-pcm", channels: 1, frameCount: 2400, sampleRate: 24000))
            parts = [.audio(pcm), .text("describe")]
        } else {
            parts = [.image(.init(height: 4, width: 4, planarRGB: (0..<48).map { Float($0) })), .text("describe")]
        }
        let events = try await value.load.submitDecodedMedia(
            .init(messages: [.init(role: .user, content: parts)],
                  additionalContext: ["enable_thinking": false], maximumOutputTokens: 2),
            request: .init(model: modelID, messages: [], temperature: 0, max_tokens: 2),
            acquired: acquired)
        var terminals = 0
        for await event in events {
            switch event {
            case .error(let message): XCTFail(message)
            case .terminal: XCTFail("unexpected media failure")
            case .info: terminals += 1
            default: break
            }
        }
        XCTAssertEqual(terminals, 1)
        await lease.joinFromOutside()
        await joinRequestConsumers(value)
        XCTAssertEqual(value.store.stats().filesWritten, before, "media must not donate a token-only checkpoint")
        let afterMTP = value.engine.mtpMetricsSnapshot()
        if let beforeMTP {
            let afterMTP = try XCTUnwrap(afterMTP)
            XCTAssertEqual(afterMTP.rounds, beforeMTP.rounds)
            XCTAssertEqual(afterMTP.draftedTokens, beforeMTP.draftedTokens)
            XCTAssertEqual(afterMTP.serialVerificationRounds, beforeMTP.serialVerificationRounds)
            XCTAssertEqual(afterMTP.rectangularVerificationRounds, beforeMTP.rectangularVerificationRounds)
        } else { XCTAssertNil(afterMTP) }
        XCTAssertEqual(value.transaction.managedMediaReservationCountForTesting, 0)
        XCTAssertTrue(value.transaction.ownsNativeCompletePrefixRequestCharge(
            engine: value.engine, bridge: value.bundle.bridge, budget: value.budget))
    }
    private func retire(_ value: Loaded) async throws {
        let contract = try XCTUnwrap(value.engine.nativeShutdownExecutionContractID)
        do {
            _ = try await value.bundle.bridge.shutdownNativeConstruction(expectedEngine: value.engine,
                executionContractID: contract)
        } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
            let snapshot = await value.bundle.bridge.nativeRetirementTaskSnapshot()
            XCTAssertEqual(snapshot.sdkQuiescence?.engineID, value.engine.nativeShutdownEngineID)
            XCTAssertEqual(snapshot.sdkQuiescence?.executionContractID, contract)
            guard snapshot.sdkQuiescence != nil else { throw Failure.completion }
            for task in snapshot.tasks { await task.value }
        }
        guard case .retired(let receipt) = await value.load.finishFailureAfterUnwind() else { throw Failure.completion }
        XCTAssertEqual(receipt.engine?.engineID, value.engine.nativeShutdownEngineID)
        XCTAssertEqual(receipt.engine?.executionContractID, contract)
        XCTAssertTrue(value.store.isClosed)
        XCTAssertEqual(value.budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertTrue(value.registry.retainedTransactionIDs.isEmpty)
    }
    private func exercise(audio: Bool, mtp: Bool) async throws {
        let value = try await loaded(audio: audio, mtp: mtp)
        let identity = value.engine.nativeShutdownEngineID
        let first = try await text(value, id: "joint-cold")
        XCTAssertEqual(first.1, 0)
        XCTAssertGreaterThan(value.store.stats().filesWritten, 0)
        let warm = try await text(value, id: "joint-warm")
        XCTAssertEqual(warm.0, first.0); XCTAssertGreaterThan(warm.1, 0)
        try await media(value, audio: audio)
        let after = try await text(value, id: "joint-after-media")
        XCTAssertEqual(after.0, first.0); XCTAssertGreaterThan(after.1, 0)
        XCTAssertEqual(value.engine.nativeShutdownEngineID, identity)
        XCTAssertEqual(value.engine.mtpMetricsSnapshot()?.active == true, mtp)
        try await retire(value)
    }
    func testActualFactoryVisualPrefixAndImageKeepOneEngineAndOneKVCharge() async throws {
        try await exercise(audio: false, mtp: false)
    }
    func testActualFactoryAudioPrefixAndPCMKeepSidecarAndExactTextMTP() async throws {
        try await exercise(audio: true, mtp: true)
    }
    func testActualJointFactoryRejectsASecondWarmAssemblyWithoutRevokingLiveOwner() async throws {
        let value = try await loaded(audio: false, mtp: false)
        let epoch = value.transaction.snapshot().constructionEpoch
        let raw = try XCTUnwrap(value.container.autoregressive)
        do { try value.transaction.claimSlotAssembly(raw); XCTFail("duplicate assembly accepted") }
        catch MiMoV26NativeTransactionError.warmRebuildUnsupported { }
        XCTAssertEqual(value.transaction.snapshot().constructionEpoch, epoch)
        XCTAssertTrue(value.transaction.ownsNativeCompletePrefixRequestCharge(
            engine: value.engine, bridge: value.bundle.bridge, budget: value.budget))
        _ = try await text(value, id: "joint-after-refusal")
        try await retire(value)
    }
}

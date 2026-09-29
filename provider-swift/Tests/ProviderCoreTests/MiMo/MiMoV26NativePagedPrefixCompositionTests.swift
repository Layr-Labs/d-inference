// Copyright © 2026 Eigen Labs.
import Foundation
import Dispatch
import MLX
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
@testable import MLXLMCommon
import XCTest
@testable import ProviderCore

/// Real encrypted-store construction and the existing GlobalKVCacheBudget
/// owner. The three original host selectors and two late-close regressions
/// remain unchanged. Native selectors also exercise actual cache-factory
/// refusal and uncached reuse; no receipt, M credit or full-model result is fabricated.
final class MiMoV26NativePagedPrefixCompositionTests: XCTestCase {
    func testNativeTargetPagingServesAfterActualNoStoreCacheRefusal() async throws {
        try await noStoreFallback(mtp: false)
    }

    func testNativeSerialMTPPagingServesAfterActualNoStoreCacheRefusal() async throws {
        try await noStoreFallback(mtp: true)
    }

    private func noStoreFallback(mtp: Bool) async throws {
        let flags = ProcessInfo.processInfo.environment
        guard flags["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1",
              flags["MIMO_V26_NATIVE_PAGED_TESTS"] == "1",
              flags["MIMO_V26_PAGED_PREFIX_TESTS"] == "1",
              let path = flags["MIMO_V26_NATIVE_PAGED_FIXTURE_ROOT"] else {
            throw XCTSkip("Requires the genuine strict fixture, bound runtime identity and exclusive native lane")
        }
        guard flags["MIMO_V26_HOST_FAULT_CASE"] == nil, flags["MIMO_V26_PAGED_PREFIX_FAULT"] == nil else {
            throw XCTSkip("Retained native faults run separately")
        }
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: URL(fileURLWithPath: path)))
        let configuration = load.plan.bundlePlan.configuration
        guard load.plan.bundlePlan.tensorBytes <= 128 << 20,
              configuration.hiddenSize <= 64, configuration.numHiddenLayers <= 4,
              configuration.numNextnPredictLayers == 3, configuration.slidingWindow == 128,
              configuration.maxPositionEmbeddings >= 256 else { throw NativeFixtureError.requiredFixture }
        for layer in 0..<configuration.numHiddenLayers {
            let g = try configuration.attentionGeometry(at: layer)
            guard g.headDim == 192, g.valueHeadDim == 128, g.queryHeads == 64,
                  [4, 8].contains(g.keyValueHeads) else { throw NativeFixtureError.requiredFixture }
        }
        let root = load.plan.canonicalRoot
        let modelID = "native-paged-no-store-fixture"
        // A new SINGLE regular file cannot be an SSD cache directory. The
        // actual no-follow factory refuses it BEFORE loading any key material.
        let refusedRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("mimo-no-store-" + UUID().uuidString)
        try Data([0x50]).write(to: refusedRoot, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: refusedRoot) }
        let environment = [
            "DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_MIMO_COMPLETE_PREFIX": "1",
            "DARKBLOOM_PREFIX_CACHE_MEMORY": "0", "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: refusedRoot.path
        ]
        XCTAssertTrue(SSDPrefixCacheFactory.forceEphemeralKey(environment: environment))
        XCTAssertEqual(SSDPrefixCacheFactory.cacheRootDirectory(environment: environment).path, refusedRoot.path)
        guard bindRuntimeMetallibForMLX() != nil else { throw NativeFixtureError.requiredFixture }
        let weightHash = try XCTUnwrap(WeightHasher.computeHash(snapshotDir: root, modelID: modelID))
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        let registry = MiMoV26NativeLoadRegistry()
        defer {
            if !registry.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(registry) }
        }
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let transaction = try XCTUnwrap(load.transaction)
        do {
            let returned = try await load.load()
            let raw = try XCTUnwrap(returned.autoregressive)
            let intent = try MiMoV26ServingLoad.preparation(mode: mtp ? .on : .off,
                externalPath: nil, environment: environment)
            let preparation = try await EngineV2SlotFactory.prepareProductionModel(modelId: modelID,
                isVLM: false, modelDirectory: root, container: returned, specDecPreparation: intent)
            guard case .nativeMiMo(let prepared) = preparation else { throw NativeFixtureError.completion }
            try transaction.claimSlotAssembly(raw)
            let owner = MiMoV26NativePagedResources(transactionID: transaction.id,
                sessionID: load.request.sessionID, budget: budget)
            let sameProcessOwner = owner.processOwner
            let config = CBv2MTPConfig(enabled: mtp, maxDraftTokens: 3,
                maxSpeculativeBatch: 1, verificationMode: .serialTarget)
            let assembled = try await transaction.performSetup {
                try transaction.registerNativePagedResources(owner)
                let metadata = try await transaction.withNativeConstruction { model, scope in
                    let binding = try model.makeCBv2Binding(enableMTP: mtp, verificationMode: .serialTarget)
                    _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    return try model.nativePagedCompletePrefixMetadata(binding: binding,
                        bytesCapacity: 768 << 20, maximumConcurrentRequests: 1,
                        maximumQueryTokens: 32, maximumPrefillChunk: 16, retaining: scope)
                }
                // This is the REAL factory/helper nil branch: it closes/joins
                // the empty attempt, then returns an honest uncached profile.
                let prefix = try await EngineV2SlotFactory.prepareNativeMiMoPagedPrefix(
                    modelId: modelID, modelDirectory: root, weightHash: weightHash, prepared: prepared,
                    metadata: metadata, paging: owner, mtpConfig: config, environment: environment,
                    persistentTestNamespace: nil)
                guard prefix.metadata == nil, prefix.status.state == .error,
                      prefix.status.reason == .cacheInitFailed, owner.store == nil else {
                    throw NativeFixtureError.completion
                }
                XCTAssertTrue(owner.processOwner === sameProcessOwner)
                XCTAssertEqual(owner.processOwner.snapshot()?.chargedBytes, 0)
                XCTAssertEqual(owner.processOwner.snapshot()?.materializedBytes, 0)
                let native = try await transaction.withNativeConstruction { model, scope in
                    let binding = try model.makeCBv2Binding(enableMTP: mtp, verificationMode: .serialTarget)
                    _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    let handle = binding.assistant.map { ProviderMTPAssistantHandle(owner: $0, drafter: $0) }
                    if let handle {
                        handle.bind(sourceTarget: model, servingTarget: model)
                        try transaction.registerAssistant(handle)
                    }
                    let resources: MiMoV26CBv2NativePagedExecutionResources
                    if mtp {
                        resources = try model.makeNativePagedSerialMTPExecutionResources(binding: binding,
                            bytesCapacity: 768 << 20, maximumConcurrentRequests: 1,
                            maximumQueryTokens: 32, maximumPrefillChunk: 16,
                            processMemoryOwner: sameProcessOwner, retaining: scope)
                    } else {
                        resources = try model.makeNativePagedExecutionResources(binding: binding,
                            bytesCapacity: 768 << 20, maximumConcurrentRequests: 1,
                            maximumQueryTokens: 32, maximumPrefillChunk: 16,
                            processMemoryOwner: sameProcessOwner, retaining: scope)
                    }
                    let geometry = try MiMoV26AdmissionGeometry(layerKinds: metadata.prefix.layerKinds,
                        probedDTypes: metadata.prefix.layerDTypes,
                        maximumContextTokens: metadata.prefix.maximumContextTokens)
                    let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                        backend: resources.backend, cacheProvider: resources.cacheProvider,
                        schedulerConfig: .init(maxConcurrentRequests: 1, maxBatchedTokensPerStep: 32,
                            prefillChunkSize: 16, enablePrefixCache: false),
                        loopConfig: .init(stepTimeout: 30, watchdogInterval: 0.01, shutdownTimeout: 10),
                        admissionConfig: geometry.internalAdmissionConfig,
                        mtpDrafter: binding.assistant, mtpConfig: config,
                        processMemoryOwner: sameProcessOwner,
                        nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                    try transaction.registerEngine(engine, executionContract: resources.contract)
                    XCTAssertTrue(resources.contract.supportsNativePagedTarget)
                    XCTAssertEqual(resources.contract.supportsNativePagedSerialMTP, mtp)
                    XCTAssertFalse(resources.contract.supportsNativeCompletePrefix)
                    XCTAssertNil(engine.completePrefixCache)
                    XCTAssertTrue(engine.usesProcessMemoryOwner(sameProcessOwner))
                    XCTAssertTrue(owner.matches(engine: engine, contract: resources.contract))
                    XCTAssertNil(engine.nativeCompletionFault); XCTAssertNil(engine.pagedAttentionWorkInactiveReason)
                    if mtp {
                        XCTAssertNil(engine.mtpInactiveReason)
                        XCTAssertTrue(engine.mtpMetricsSnapshot()?.active == true)
                        XCTAssertEqual(engine.mtpMetricsSnapshot()?.verificationMode, .serialTarget)
                        guard case .bounded? = engine.resolvedMTPAdmission else {
                            throw NativeFixtureError.completion
                        }
                    }
                    let fixed = try geometry.sharedFixedRequestBytes(
                        resolvedNonTargetFixedBytes: engine.resolvedFixedBytesPerRequest)
                    return (engine, handle, resources.contract, geometry.fullKVBytesPerToken, fixed)
                }
                let tokenizer = await raw.perform { TokenizerHandle($0.tokenizer) }
                let bridge = try EngineV2Factory.makeBridge(modelId: modelID, tokenizer: tokenizer,
                    eosTokenIds: [], defaultMaxTokens: 8, maxConcurrentRequests: 1,
                    advertisedContextTokens: configuration.maxPositionEmbeddings,
                    runtimePolicyEnvironment: environment, kvBytesPerToken: native.3, kvBudget: budget,
                    ssdHybridCheckpointStore: nil,
                    prefixCacheStatus: .init(modelId: modelID, backend: .paged, replayStrategy: .none,
                        state: prefix.status.state, reason: prefix.status.reason)) {
                    .init(engine: native.0, fixedRequestBytes: native.4, kvBackendKind: .paged,
                        kvBackendFallbackReason: nil, mtpAdmissionResolution: native.0.resolvedMTPAdmission)
                }
                try transaction.registerBridge(bridge)
                try await bridge.attachNativeTransaction(transaction)
                let bundle = ProviderEngineBundle(bridge: bridge, assistant: native.1, assistantBytes: 0,
                    mtpArtifact: nil, mtpStatus: .init(configured: mtp, active: mtp, reason: nil,
                        source: mtp ? .inline : nil, revision: nil, artifactBytes: 0, assistantBytes: 0))
                try transaction.registerBundle(bundle)
                return (native.0, native.2, bundle)
            }
            let engine = assembled.0, contract = assembled.1, bundle = assembled.2
            _ = try await load.sealConstructionForPublication()
            try load.commitPublication {}
            XCTAssertTrue(owner.matches(engine: engine, contract: contract))
            XCTAssertTrue(transaction.ownsNativePagedRequestCharge(
                engine: engine, bridge: bundle.bridge, budget: budget),
                "closing only an EMPTY cache attempt must not disable the real request-charge owner")
            XCTAssertEqual(bundle.bridge.prefixCacheModelStatus().reason, .cacheInitFailed)
            XCTAssertNil(engine.completePrefixCache)
            let submission = try engine.submitWithNativeRetirement(.init(id: .init(97_410),
                promptTokens: Array(repeating: 12, count: 17), sampling: .init(temperature: 0), maxTokens: 8))
            var tokenCount = 0, terminals = 0
            for await event in submission.events {
                switch event {
                case .delta(_, let tokens, _): tokenCount += tokens.count
                case .finished(let reason, let usage):
                    XCTAssertEqual(reason, .length); XCTAssertEqual(usage.completionTokens, 8)
                    XCTAssertEqual(usage.prefixCachePrefillTokensSaved, 0); terminals += 1
                }
            }
            await submission.retirement.wait()
            XCTAssertEqual(tokenCount, 8); XCTAssertEqual(terminals, 1)
            guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else {
                throw NativeFixtureError.completion
            }
            XCTAssertEqual(receipt.engine?.engineID, engine.nativeShutdownEngineID)
            XCTAssertEqual(receipt.engine?.executionContractID, contract.id)
            XCTAssertNil(sameProcessOwner.snapshot())
            XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
            XCTAssertTrue(registry.retainedTransactionIDs.isEmpty); XCTAssertFalse(registry.hasRetainedFault)
            withExtendedLifetime(raw) {}; withExtendedLifetime(returned) {}; withExtendedLifetime(bundle) {}
        } catch {
            _ = await load.finishFailureAfterUnwind()
            throw error
        }
    }

    private enum NativeFixtureError: Error { case requiredFixture, gateTimeout, completion }

    /// A test-only interleaving barrier inside the EXISTING synchronous
    /// construction body. No production hook, engine marker or receipt.
    private final class NativeBindGate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let releaseSignal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var actualIDs: (UUID, UUID)?
        private var rejectedForClosing = false
        private var matchedWhileClosing = false
        private var capturedByTransaction = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func hold(engine: EngineV2, contract: CBv2NativeExecutionContract) -> Bool {
            lock.withLock { actualIDs = (engine.nativeShutdownEngineID, contract.id) }
            entered.fulfill()
            return releaseSignal.wait(timeout: .now() + 20) == .success
        }
        func release() { releaseSignal.signal() }
        func recordRefusal(_ error: Error, servingMatch: Bool, transactionCaptured: Bool) {
            lock.withLock {
                if case .foreignOwner? = error as? MiMoV26NativePagedResources.Failure {
                    rejectedForClosing = true
                }
                matchedWhileClosing = servingMatch
                capturedByTransaction = transactionCaptured
            }
        }
        var snapshot: (ids: (UUID, UUID)?, closing: Bool, serving: Bool, captured: Bool) {
            lock.withLock { (actualIDs, rejectedForClosing, matchedWhileClosing, capturedByTransaction) }
        }
    }

    func testNativeTargetPrefixLateRetireKeepsActualEngineReceiptIdentity() async throws {
        try await lateRetirement(mtp: false)
    }

    func testNativeSerialMTPPrefixLateRetireKeepsActualEngineReceiptIdentity() async throws {
        try await lateRetirement(mtp: true)
    }

    private func lateRetirement(mtp: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIMO_V26_SERIAL_NATIVE_TESTS"] == "1",
              env["MIMO_V26_NATIVE_PAGED_TESTS"] == "1",
              env["MIMO_V26_PAGED_PREFIX_TESTS"] == "1",
              let path = env["MIMO_V26_NATIVE_PAGED_FIXTURE_ROOT"] else {
            throw XCTSkip("Requires a genuine bounded strict MiMo paging fixture and the exclusive native lane")
        }
        guard env["MIMO_V26_HOST_FAULT_CASE"] == nil,
              env["MIMO_V26_PAGED_PREFIX_FAULT"] == nil else {
            throw XCTSkip("Retained native faults run alone; do not share this healthy retirement process")
        }
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: URL(fileURLWithPath: path)))
        let configuration = load.plan.bundlePlan.configuration
        guard load.plan.bundlePlan.tensorBytes <= 128 << 20,
              configuration.hiddenSize <= 64, configuration.numHiddenLayers <= 4,
              configuration.numNextnPredictLayers == 3, configuration.slidingWindow == 128,
              configuration.maxPositionEmbeddings >= 256 else { throw NativeFixtureError.requiredFixture }
        for layer in 0..<configuration.numHiddenLayers {
            let geometry = try configuration.attentionGeometry(at: layer)
            guard geometry.headDim == 192, geometry.valueHeadDim == 128,
                  geometry.queryHeads == 64, [4, 8].contains(geometry.keyValueHeads) else {
                throw NativeFixtureError.requiredFixture
            }
        }
        // Production budget reader/reserves and genuine claim/load. This test
        // never clears or fabricates an engine/process charge.
        let budget = GlobalKVCacheBudget(configReserveBytes: 4 << 30)
        let registry = MiMoV26NativeLoadRegistry()
        defer {
            // Preserve a failed ORIGINAL control or unexpected native failure;
            // no timeout/refund/destructor is relabelled a retirement receipt.
            if !registry.retainedTransactionIDs.isEmpty { _ = Unmanaged.passRetained(registry) }
        }
        try load.claim(budget: budget, lifecycle: registry.openLifecycle(), registry: registry)
        let transaction = try XCTUnwrap(load.transaction)
        let returned = try await load.load()
        let raw = try XCTUnwrap(returned.autoregressive)
        try transaction.claimSlotAssembly(raw)
        let owner = MiMoV26NativePagedResources(transactionID: transaction.id,
            sessionID: load.request.sessionID, budget: budget)
        let gate = NativeBindGate(expectation(description: "real engine constructed; not yet registered"))
        defer { gate.release() }
        let setup = Task<Void, Error> {
            try await transaction.performSetup {
                try transaction.registerNativePagedResources(owner)
                let metadata = try await transaction.withNativeConstruction { model, scope in
                    let binding = try model.makeCBv2Binding(enableMTP: mtp, verificationMode: .serialTarget)
                    _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    return try model.nativePagedCompletePrefixMetadata(binding: binding,
                        bytesCapacity: 768 << 20, maximumConcurrentRequests: 1,
                        maximumQueryTokens: 32, maximumPrefillChunk: 16, retaining: scope)
                }
                let store = try MiMoPrefixStoreTestSupport.store(
                    budget: budget, layout: metadata.prefix.backendLayout)
                try owner.preparePrefix(identity: store.identity, backendLayout: metadata.prefix.backendLayout)
                try owner.installPrefix(store)
                try await transaction.withNativeConstruction { model, scope in
                    let binding = try model.makeCBv2Binding(enableMTP: mtp, verificationMode: .serialTarget)
                    _ = try binding.adapter.probeNativeKVTypes(retaining: scope)
                    let resources = try model.makeNativePagedCompletePrefixExecutionResources(binding: binding,
                        bytesCapacity: 768 << 20, maximumConcurrentRequests: 1,
                        maximumQueryTokens: 32, maximumPrefillChunk: 16, expectedMetadata: metadata,
                        completePrefixCache: store, processMemoryOwner: owner.processOwner, retaining: scope)
                    let geometry = try MiMoV26AdmissionGeometry(layerKinds: metadata.prefix.layerKinds,
                        probedDTypes: metadata.prefix.layerDTypes,
                        maximumContextTokens: metadata.prefix.maximumContextTokens)
                    let engine = EngineV2(model: binding.adapter, layerKinds: binding.adapter.layerKinds,
                        backend: resources.backend, cacheProvider: resources.cacheProvider,
                        schedulerConfig: .init(maxConcurrentRequests: 1, maxBatchedTokensPerStep: 32,
                            prefillChunkSize: 16, enablePrefixCache: true),
                        loopConfig: .init(stepTimeout: 30, watchdogInterval: 0.01, shutdownTimeout: 10),
                        admissionConfig: geometry.internalAdmissionConfig, completePrefixCache: store,
                        mtpDrafter: binding.assistant, mtpConfig: .init(enabled: mtp,
                            maxDraftTokens: 3, maxSpeculativeBatch: 1, verificationMode: .serialTarget),
                        processMemoryOwner: owner.processOwner,
                        nativeCompletionTracking: true, nativeExecutionContract: resources.contract)
                    try scope.retainOwner(engine)
                    XCTAssertTrue(resources.contract.supportsNativePagedTarget)
                    XCTAssertTrue(resources.contract.supportsNativeCompletePrefix)
                    XCTAssertEqual(resources.contract.supportsNativePagedSerialMTP, mtp)
                    XCTAssertTrue(engine.completePrefixCache === store)
                    XCTAssertTrue(engine.usesProcessMemoryOwner(owner.processOwner))
                    XCTAssertNil(engine.nativeCompletionFault); XCTAssertNil(engine.pagedAttentionWorkInactiveReason)
                    let released = gate.hold(engine: engine, contract: resources.contract)
                    // Even a barrier timeout must pass the genuine engine to
                    // TX before failing, so test failure cannot discard it.
                    do {
                        try transaction.registerEngine(engine, executionContract: resources.contract)
                    } catch {
                        gate.recordRefusal(error,
                            servingMatch: owner.matches(engine: engine, contract: resources.contract),
                            transactionCaptured: transaction.snapshot().hasEngine)
                        throw error
                    }
                    guard released else { throw NativeFixtureError.gateTimeout }
                    XCTFail("late closed owner must refuse serving")
                }
            }
        }
        await fulfillment(of: [gate.entered], timeout: 10)
        guard gate.snapshot.ids != nil else {
            gate.release(); _ = await setup.result
            _ = await load.finishFailureAfterUnwind()
            throw NativeFixtureError.completion
        }
        XCTAssertGreaterThan(transaction.snapshot().activeOperations, 0)
        XCTAssertFalse(transaction.snapshot().hasEngine)
        let store = try XCTUnwrap(owner.store)
        XCTAssertFalse(store.isClosed)
        let charged = budget.processLedger.snapshot().chargedBytes
        XCTAssertGreaterThan(charged, 0, "actual full load/setup reservation must still be owned")
        let early = await transaction.retire() // real revoke/close while SDK body is held
        guard case .pending(.activeOperations) = early else {
            gate.release(); _ = await setup.result
            _ = await load.finishFailureAfterUnwind()
            throw NativeFixtureError.completion
        }
        XCTAssertTrue(store.isClosed)
        XCTAssertNotNil(owner.processOwner.snapshot())
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, charged)
        gate.release()
        var setupError: Error?
        do { try await setup.value; XCTFail("late construction must not publish") }
        catch { setupError = error }
        if case .foreignOwner? = setupError as? MiMoV26NativePagedResources.Failure {}
        else { XCTFail("expected the late serving veto, not a foreign-tuple/fixture failure") }
        let observation = gate.snapshot
        XCTAssertTrue(observation.closing); XCTAssertFalse(observation.serving)
        XCTAssertTrue(observation.captured)
        XCTAssertTrue(transaction.snapshot().hasEngine)
        XCTAssertFalse(transaction.snapshot().hasBridge); XCTAssertFalse(transaction.snapshot().hasBundle)
        XCTAssertEqual(transaction.snapshot().activeOperations, 0)
        XCTAssertFalse(registry.hasRetainedFault)
        // Run the actual cleanup even on the original bug's foreignOwner
        // error. That control reaches paged_ledger_retirement_failed because
        // the owner discarded the real IDs; it must not fail only on wording.
        guard case .retired(let receipt) = await load.finishFailureAfterUnwind() else {
            throw NativeFixtureError.completion
        }
        let ids = try XCTUnwrap(observation.ids)
        XCTAssertEqual(receipt.engine?.engineID, ids.0)
        XCTAssertEqual(receipt.engine?.executionContractID, ids.1)
        XCTAssertTrue(store.isClosed)
        XCTAssertNil(owner.processOwner.snapshot(), "actual Common settlement, never a test refund")
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        XCTAssertFalse(transaction.snapshot().hasEngine)
        XCTAssertTrue(registry.retainedTransactionIDs.isEmpty)
        XCTAssertFalse(registry.hasRetainedFault)
        try FileManager.default.removeItem(at: store.config.dedicatedRoot)
        // Caller aliases are passive; this is ownership retirement, not a
        // claim that the allocator/OS has physically reclaimed every byte.
        withExtendedLifetime(raw) {}; withExtendedLifetime(returned) {}
    }

    func testJointStoreUsesOneExistingOwnerAndRequiresActualCloseJoin() async throws {
        for layout in [CBv2CompleteCheckpointManifest.pagedAsymmetricLayout,
                       CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout] {
            let budget = MiMoPrefixStoreTestSupport.budget()
            let owner = MiMoV26NativePagedResources(
                transactionID: UUID(), sessionID: UUID(), budget: budget)
            let sameOwner = owner.processOwner
            let store = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: layout)
            try owner.preparePrefix(identity: store.identity, backendLayout: layout)
            try owner.installPrefix(store)
            XCTAssertTrue(owner.processOwner === sameOwner)
            XCTAssertTrue(owner.store === store)
            XCTAssertTrue(store.kvBudget === budget)
            XCTAssertThrowsError(try owner.retireUnusedOwner())
            owner.close()
            XCTAssertTrue(store.isClosed)
            XCTAssertThrowsError(try owner.retireUnusedOwner(), "close is not the actual IO join")
            await owner.closeAndWait()
            try owner.retireUnusedOwner()
            XCTAssertNil(sameOwner.snapshot())
            try FileManager.default.removeItem(at: store.config.dedicatedRoot)
        }
    }

    func testLateStoreIsCapturedThenClosedAndDuplicateCannotReplaceIt() async throws {
        let budget = MiMoPrefixStoreTestSupport.budget()
        let layout = CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout
        let owner = MiMoV26NativePagedResources(transactionID: UUID(), sessionID: UUID(), budget: budget)
        let actual = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: layout)
        let duplicate = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: layout)
        try owner.preparePrefix(identity: actual.identity, backendLayout: layout)
        owner.close() // actual setup cancellation before the awaited factory result
        try owner.installPrefix(actual)
        XCTAssertTrue(owner.store === actual); XCTAssertTrue(actual.isClosed)
        XCTAssertThrowsError(try owner.installPrefix(duplicate))
        XCTAssertFalse(duplicate.isClosed, "no ownership of a rejected foreign result")
        XCTAssertThrowsError(try owner.retireUnusedOwner())
        await owner.closeAndWait()
        try owner.retireUnusedOwner()
        await duplicate.closeAndWait()
        try FileManager.default.removeItem(at: actual.config.dedicatedRoot)
        try FileManager.default.removeItem(at: duplicate.config.dedicatedRoot)
    }

    func testForeignBudgetLayoutIdentityAndRealOutstandingChargeRemainRefused() async throws {
        let budget = MiMoPrefixStoreTestSupport.budget(), foreign = MiMoPrefixStoreTestSupport.budget()
        let layout = CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout
        let stores = [
            try MiMoPrefixStoreTestSupport.store(budget: foreign, layout: layout),
            try MiMoPrefixStoreTestSupport.store(budget: budget,
                layout: CBv2CompleteCheckpointManifest.pagedAsymmetricLayout)
        ]
        let owner = MiMoV26NativePagedResources(transactionID: UUID(), sessionID: UUID(), budget: budget)
        try owner.preparePrefix(identity: MiMoPrefixStoreTestSupport.identity, backendLayout: layout)
        for store in stores {
            XCTAssertThrowsError(try owner.installPrefix(store))
            XCTAssertFalse(store.isClosed); XCTAssertNil(owner.store)
        }
        let identityMismatch = MiMoV26NativePagedResources(
            transactionID: UUID(), sessionID: UUID(), budget: foreign)
        let otherIdentity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: String(repeating: "e", count: 64),
            promptContractID: MiMoPrefixStoreTestSupport.identity.promptContractID,
            buildID: MiMoPrefixStoreTestSupport.identity.buildID,
            numericsFingerprint: MiMoPrefixStoreTestSupport.identity.numericsFingerprint)
        try identityMismatch.preparePrefix(identity: otherIdentity, backendLayout: layout)
        XCTAssertThrowsError(try identityMismatch.installPrefix(stores[0]))
        XCTAssertFalse(stores[0].isClosed)
        await identityMismatch.closeAndWait()
        try identityMismatch.retireUnusedOwner()
        XCTAssertThrowsError(try owner.preparePrefix(identity: MiMoPrefixStoreTestSupport.identity,
            backendLayout: layout), "one immutable namespace preparation")
        try owner.processOwner.replaceCharge(4096) // actual host C; no native array exists
        await owner.closeAndWait()
        XCTAssertThrowsError(try owner.retireUnusedOwner())
        XCTAssertEqual(owner.processOwner.snapshot()?.chargedBytes, 4096)
        // Drop only this test's host promise; never invent native completion.
        try owner.processOwner.replaceCharge(0)
        try owner.retireUnusedOwner()
        for store in stores {
            await store.closeAndWait()
            try FileManager.default.removeItem(at: store.config.dedicatedRoot)
        }
    }
}

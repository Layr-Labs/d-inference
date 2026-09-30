import CryptoKit
import Foundation
import MLX
import MLXLLM
import ProviderCoreFoundation
import XCTest
@testable import MLXLMCommon
@testable import ProviderCore

// Prepared source only. The three real-native construction methods require
// DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1 and the root's actual Metal/resources
// setup. A qualifying run must execute every method with zero skips.
// Tiny Gemma is a real supported factory target, not a MiMo architecture alias.
// Its test drafter supplies only an admission declaration; no learned-head or
// model-quality claim is made by these construction/accounting tests.

private struct MTPAdmissionTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "x" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2] }
}

private final class MTPAdmissionObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var declarations: [ProcessMemoryLedger.Snapshot] = []
    private var retirements: [(ProcessMemoryLedger.Owner, ProcessMemoryLedger.Snapshot)] = []
    private var count = 0
    let retired: XCTestExpectation?
    init(retired: XCTestExpectation? = nil) { self.retired = retired }
    func declared(_ snapshot: ProcessMemoryLedger.Snapshot?) {
        lock.withLock { count += 1; if let snapshot { declarations.append(snapshot) } }
    }
    func removed(_ owner: ProcessMemoryLedger.Owner, snapshot: ProcessMemoryLedger.Snapshot) {
        lock.withLock { retirements.append((owner, snapshot)) }
        retired?.fulfill()
    }
    var declarationCount: Int { lock.withLock { count } }
    var declarationSnapshots: [ProcessMemoryLedger.Snapshot] { lock.withLock { declarations } }
    var removalSnapshots: [(ProcessMemoryLedger.Owner, ProcessMemoryLedger.Snapshot)] {
        lock.withLock { retirements }
    }
}

private class MTPAdmissionLegacyDrafter: CBv2MTPDrafter {
    private final class Capture: CBv2MTPPreparedCapture {}
    let target: Gemma4TextModel
    init(_ target: Gemma4TextModel) { self.target = target }
    var mtpTargetIdentity: ObjectIdentifier? { ObjectIdentifier(target) }
    var requiredVerificationMode: CBv2MTPVerificationMode? { .serialTarget }
    var maximumDraftTokens: Int? { 1 }
    var requestStateBytesPerToken: Int { 20 }
    var requestStateTokenGranularity: Int { 16 }
    var requestStateTokenAllocationPadding: Int { 3 }
    func prepare(rows: [CBv2MTPRowCapture]) -> any CBv2MTPPreparedCapture { Capture() }
    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: any CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray) {
        preconditionFailure("construction-only admission fixture must not execute draft math")
    }
}

private final class MTPAdmissionBoundedDrafter: MTPAdmissionLegacyDrafter, CBv2MTPBoundedAllocationProviding {
    let declaration: CBv2MTPBoundedAllocationSpec?
    let observations: MTPAdmissionObservations
    let ledger: ProcessMemoryLedger?
    init(_ target: Gemma4TextModel, declaration: CBv2MTPBoundedAllocationSpec?,
         observations: MTPAdmissionObservations, ledger: ProcessMemoryLedger? = nil) {
        self.declaration = declaration; self.observations = observations; self.ledger = ledger
        super.init(target)
    }
    func boundedRequestAllocation(limits: CBv2MTPAllocationLimits) -> CBv2MTPBoundedAllocationSpec? {
        observations.declared(ledger?.snapshot())
        return declaration
    }
}

/// Scripted generation boundary only for provider bridge tests. It is NOT used
/// by either direct-factory refusal test path and is never a NativeBlock engine.
private final class MTPAdmissionHeldEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CBv2Request] = []
    private var pending: [CBv2RequestID: (CBv2Request, AsyncStream<CBv2Event>.Continuation)] = [:]
    var submittedCount: Int { lock.withLock { requests.count } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { requests.append(request); pending[request.id] = (request, continuation) }
        return stream
    }
    func finishAll(cancelled: Bool = false) {
        let rows = lock.withLock { let rows = Array(pending.values); pending.removeAll(); return rows }
        for (request, stream) in rows {
            if !cancelled { stream.yield(.delta(text: "x", tokens: [7], logprobs: nil)) }
            stream.yield(.finished(reason: cancelled ? .cancelled : .stop,
                usage: .init(promptTokens: request.promptTokens.count, completionTokens: cancelled ? 0 : 1)))
            stream.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {
        let row = lock.withLock { pending.removeValue(forKey: id) }
        row?.1.yield(.finished(reason: .cancelled, usage: .init(promptTokens: 0, completionTokens: 0)))
        row?.1.finish()
    }
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: lock.withLock { pending.count }, waitingRequests: 0,
              kvBytesInUse: 0, kvBytesCapacity: 1 << 30, activeTokens: 0)
    }
    func shutdown() async { finishAll(cancelled: true) }
}

private final class MTPAdmissionTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TelemetryEvent] = []
    func record(_ event: TelemetryEvent) { lock.withLock { values.append(event) } }
    var events: [TelemetryEvent] { lock.withLock { values } }
}

final class EngineV2MTPProductionAdmissionTests: XCTestCase {
    private let counts = [1, 2, 3, 127, 128, 129, 1024, 262_144, 1_048_576]
    private var enabled: CBv2MTPConfig {
        .init(enabled: true, maxDraftTokens: 1, maxSpeculativeBatch: 1,
              fixedDraftTokens: 1, verificationMode: .serialTarget)
    }
    private var environment: [String: String] { [KVBackendGuardStore.pathEnvKey: "/dev/null"] }
    private var bounded: CBv2MTPAdmissionResolution {
        .bounded(.init(limits: .init(maximumPrefillTokens: 512, maximumDraftTokens: 1),
            residentBytes: 100, workingBytes: 200, hostBytes: 20, fixedBytesPerRequest: 320))
    }
    private var validDeclaration: CBv2MTPBoundedAllocationSpec {
        .init(resident: [.init(logicalBytes: 4096, allocationCount: 4)],
              working: [.init(logicalBytes: 1024, allocationCount: 3)], hostBytes: 256)
    }
    private func requireNativeLane() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1" else {
            throw XCTSkip("Root exclusive native lane required; qualifying run requires zero skips")
        }
        XCTAssertTrue(CBv2MTPConfig.envEnabled, "A disabled driver is not a refusal test")
        _ = try XCTUnwrap(CBv2MTPConfig.envEnabled ? true : nil)
        _ = try XCTUnwrap(Memory.allocationFootprintPolicy(), "Actual allocator policy is a prerequisite")
    }
    private func makeTarget() throws -> Gemma4TextModel {
        let data = Data("""
        {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":2,
         "intermediate_size":128,"num_attention_heads":4,"head_dim":64,"global_head_dim":64,
         "vocab_size":128,"vocab_size_per_layer_input":128,"num_key_value_heads":2,
         "num_kv_shared_layers":0,"hidden_size_per_layer_input":32,"sliding_window":16,
         "sliding_window_pattern":2,"max_position_embeddings":2048,"use_double_wide_mlp":false}
        """.utf8)
        let value = Gemma4TextModel(try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data))
        let captures = try XCTUnwrap(value.cbv2MTPCaptureLayers)
        XCTAssertNotEqual(captures.full, captures.sliding)
        XCTAssertNotNil(EngineV2Factory.ProductionModelAdapter(model: value))
        return value
    }
    private func makeBudget() -> GlobalKVCacheBudget {
        // Controlled usage isolates owner accounting; this is NOT an actual
        // process-peak measurement. The ledger, owners and factories are real.
        GlobalKVCacheBudget(activationReserveBytes: 0, memorySnapshot: {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max)
        })
    }
    private func build(_ target: Gemma4TextModel, drafter: (any CBv2MTPDrafter)?,
                       paged: Bool, budget: GlobalKVCacheBudget? = nil) throws -> EngineV2Factory.ProductionBuild {
        try EngineV2Factory.makeProductionBuild(model: target, tokenizer: MTPAdmissionTokenizer(),
            kvBytesCapacity: 128 << 20, maxConcurrentRequests: 1, kvBudget: budget,
            mtpDrafter: drafter, mtpConfig: enabled, kvBackend: paged ? .paged : .contiguous,
            maxContextLength: 2048, environment: environment)
    }

    func testEmptyRetirementObserverIsPerLedgerOnceAndOutsideLock() throws {
        let ledger = ProcessMemoryLedger(policy: .init(epoch: 1, capBytes: 1024, reserveBytes: 0),
            readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max) })
        let recorded = MTPAdmissionObservations()
        ledger.setEmptyOwnerRetirementObserverForTesting { [weak ledger] owner in
            guard let ledger else { return }
            // Reentering snapshot would deadlock if the observer ran under lock.
            recorded.removed(owner, snapshot: ledger.snapshot())
        }
        let empty = ledger.createOwner()
        XCTAssertEqual(ledger.retire(empty.owner), .retired)
        XCTAssertEqual(recorded.removalSnapshots.count, 1)
        XCTAssertEqual(recorded.removalSnapshots.first?.0, empty.owner)
        XCTAssertEqual(recorded.removalSnapshots.first?.1.ownerCount, 0)
        XCTAssertEqual(ledger.retire(empty.owner), .alreadyRetired)
        XCTAssertEqual(recorded.removalSnapshots.count, 1)
        let other = ledger.createOwner()
        let funded = try ledger.replaceCharge(owner: other.owner, expectedRevision: other.revision,
            expectedPolicyEpoch: 1, chargedBytes: 7)
        XCTAssertEqual(ledger.retire(funded.owner), .draining(chargedBytes: 7, materializedBytes: 0))
        XCTAssertEqual(recorded.removalSnapshots.count, 1)
        let closing = try XCTUnwrap(ledger.state(for: funded.owner))
        _ = try ledger.replaceCharge(owner: closing.owner, expectedRevision: closing.revision,
            expectedPolicyEpoch: 0, chargedBytes: 0) // ordinary cleanup of this scalar-only unit owner
        XCTAssertEqual(ledger.retire(closing.owner), .alreadyRetired)
        XCTAssertEqual(recorded.removalSnapshots.count, 1, "install-path removal is not retire's empty-owner event")
        ledger.setEmptyOwnerRetirementObserverForTesting(nil)
        XCTAssertEqual(ledger.retire(ledger.createOwner().owner), .retired)
        XCTAssertEqual(recorded.removalSnapshots.count, 1)
    }

    func testBothRealDirectFactoriesRefuseExactlyAndRetireUnpublishedSegmentedOwner() async throws {
        try requireNativeLane()
        for directEngine in [false, true] {
            let target = try makeTarget(), budget = makeBudget(), ledger = budget.processLedger
            let removed = expectation(description: "actual empty construction owner removed \(directEngine)")
            removed.assertForOverFulfill = true
            let observations = MTPAdmissionObservations(retired: removed)
            ledger.setEmptyOwnerRetirementObserverForTesting { [weak ledger] owner in
                guard let ledger else { return }
                observations.removed(owner, snapshot: ledger.snapshot())
            }
            let drafter = MTPAdmissionBoundedDrafter(target, declaration: nil,
                observations: observations, ledger: ledger)
            var escaped: (any CBv2Engine)?
            do {
                if directEngine {
                    escaped = try EngineV2Factory.makeProductionEngine(model: target,
                        tokenizer: MTPAdmissionTokenizer(), kvBytesCapacity: 128 << 20,
                        maxConcurrentRequests: 1, kvBudget: budget, mtpDrafter: drafter,
                        mtpConfig: enabled, kvBackend: .paged, maxContextLength: 2048, environment: environment)
                } else { escaped = try build(target, drafter: drafter, paged: true, budget: budget).engine }
                XCTFail("Unavailable active bounded declaration escaped direct production assembly")
            } catch {
                XCTAssertEqual(error as? CBv2MTPAdmissionRefusal, .missingDeclaration,
                    "Unsupported-model, disabled-driver, or preflight failure cannot satisfy this test")
            }
            XCTAssertNil(escaped)
            // Only clean up a wrongly returned engine so a failed regression run
            // does not leak it. The expected refusal path never calls shutdown.
            if let escaped { await escaped.shutdown() }
            XCTAssertEqual(observations.declarationCount, 1, "Proves the compatible real MTP driver activated")
            let during = try XCTUnwrap(observations.declarationSnapshots.first)
            XCTAssertEqual(during.ownerCount, 1)
            XCTAssertEqual(during.chargedBytes, 0);XCTAssertEqual(during.materializedBytes, 0)
            await fulfillment(of: [removed], timeout: 10)
            let after = try XCTUnwrap(observations.removalSnapshots.first?.1)
            XCTAssertEqual(observations.removalSnapshots.count, 1)
            XCTAssertEqual(after.ownerCount, 0)
            XCTAssertEqual(after.chargedBytes, 0);XCTAssertEqual(after.materializedBytes, 0)
            XCTAssertEqual(ledger.snapshot().ownerCount, 0)
            ledger.setEmptyOwnerRetirementObserverForTesting(nil)
        }
    }

    func testLegacyAndNilDraftersStillSucceedThroughBothRealDirectFactories() async throws {
        try requireNativeLane()
        for hasDrafter in [false, true] {
            for directEngine in [false, true] {
                let target = try makeTarget()
                let drafter: (any CBv2MTPDrafter)? = hasDrafter ? MTPAdmissionLegacyDrafter(target) : nil
                let returned: any CBv2Engine
                if directEngine {
                    returned = try EngineV2Factory.makeProductionEngine(model: target,
                        tokenizer: MTPAdmissionTokenizer(), kvBytesCapacity: 128 << 20,
                        maxConcurrentRequests: 1, mtpDrafter: drafter, mtpConfig: enabled,
                        kvBackend: .contiguous, maxContextLength: 2048, environment: environment)
                } else {
                    let built = try build(target, drafter: drafter, paged: false)
                    XCTAssertNil(built.mtpAdmissionResolution)
                    returned = built.engine
                }
                let engine = try XCTUnwrap(returned as? EngineV2)
                XCTAssertNil(engine.resolvedMTPAdmission)
                XCTAssertEqual(engine.resolvedFixedBytesPerRequest, 0)
                XCTAssertEqual(engine.mtpMetricsSnapshot() != nil, hasDrafter)
                XCTAssertEqual(engine.admissionForTesting.bytesReserved, 0)
                await engine.shutdown()
            }
        }
    }

    func testRealSegmentedBuildAndMakeBridgeKeepBoundedCostInNativeProcessOwner() async throws {
        try requireNativeLane()
        let target = try makeTarget(), budget = makeBudget(), observations = MTPAdmissionObservations()
        let drafter = MTPAdmissionBoundedDrafter(target, declaration: validDeclaration, observations: observations)
        let built = try build(target, drafter: drafter, paged: true, budget: budget)
        let engine = try XCTUnwrap(built.engine as? EngineV2)
        guard case .bounded(let resolved)? = built.mtpAdmissionResolution else {
            await engine.shutdown();return XCTFail("Actual producer did not resolve bounded admission")
        }
        XCTAssertEqual(observations.declarationCount, 1)
        XCTAssertEqual(built.fixedRequestBytes, resolved.fixedBytesPerRequest)
        XCTAssertTrue(built.usesProcessMemoryOwner)
        XCTAssertEqual(built.kvBackendKind, .paged)
        let bridge = try EngineV2Factory.makeBridge(modelId: "native-admission-fixture",
            tokenizer: TokenizerHandle(MTPAdmissionTokenizer()), eosTokenIds: [],
            kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
            auxiliaryTokenGranularity: 16, auxiliaryTokenAllocationPadding: 3,
            kvBudget: budget, makeEngine: { built })
        let fixed = await bridge.fixedRequestBytes, auxiliary = await bridge.auxiliaryBytesPerToken
        XCTAssertEqual(fixed, resolved.fixedBytesPerRequest);XCTAssertEqual(auxiliary, 0)
        // Drive the ACTUAL native ledger while its empty engine is idle. No fake
        // process owner, estimated materialization or serving forward is used.
        let admission = engine.admissionForTesting
        for count in [1, 17, 129] {
            try engine.loopForTesting.onEngineQueueSync {
                try admission.reserve(id: .init(700), additionalTokens: count)
            }
            XCTAssertEqual(admission.nonBackendBytesReserved, built.fixedRequestBytes)
            XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, UInt64(admission.bytesReserved))
            XCTAssertEqual(budget.processLedger.snapshot().materializedBytes, 0)
            let sharedIDs = await budget.reservationIDsForTesting()
            XCTAssertTrue(sharedIDs.isEmpty, "Native C is not a second scalar actor reservation")
            engine.loopForTesting.onEngineQueueSync { admission.releaseAll(id: .init(700)) }
            XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
        }
        await bridge.shutdown()
        XCTAssertEqual(budget.processLedger.snapshot().ownerCount, 0)
    }

    func testActualMakeBridgePricesScalarMatrixAndSharedSubmissionWithoutDoubleFixed() async throws {
        let engine = MTPAdmissionHeldEngine(), budget = makeBudget()
        let bridge = try EngineV2Factory.makeBridge(modelId: "scalar-admission-fixture",
            tokenizer: TokenizerHandle(MTPAdmissionTokenizer()), eosTokenIds: [],
            advertisedContextTokens: 1_048_576,
            kvBytesPerToken: 127, auxiliaryBytesPerToken: 27,
            auxiliaryTokenGranularity: 16, auxiliaryTokenAllocationPadding: 3,
            kvBudget: budget, makeEngine: {
                .init(engine: engine, fixedRequestBytes: 420, kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil, mtpAdmissionResolution: self.bounded, legacyMTPBytesPerToken: 20)
            })
        func expected(_ n: Int) -> Int { 100*n + ((n+3+15)/16)*16*7 + 420 }
        for count in counts {
            let actual = await bridge.requestReservationBytes(tokenCount: count)
            XCTAssertEqual(actual, expected(count))
        }
        let overhead = await bridge.maximumRequestOverheadBytes()
        XCTAssertEqual(overhead, 420 + 7*18)
        let needed = expected(129)
        XCTAssertTrue(budget.processLedger.updatePolicy(.init(epoch: 2, capBytes: UInt64(needed+99), reserveBytes: 0)))
        let other = await budget.reserveBytes(requestID: "other-owner", bytes: 99)
        XCTAssertTrue(other)
        let request = ChatCompletionRequest(model: "scalar-admission-fixture", messages: [], max_tokens: 2)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 127),
            request: request, requestId: "bounded-shared", cacheEnabled: false)
        XCTAssertEqual(engine.submittedCount, 1)
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, UInt64(needed+99))
        XCTAssertEqual(budget.processLedger.snapshot().materializedBytes, 0)
        let ids = await budget.reservationIDsForTesting()
        XCTAssertEqual(Set(ids), Set(["other-owner", "bounded-shared"]))
        let refused = await bridge.submitTokenized(promptTokens: [1], request: request,
            requestId: "cannot-fit", cacheEnabled: false)
        var errors: [String] = []
        for await event in refused { if case .error(let message) = event { errors.append(message) } }
        XCTAssertEqual(errors, ["token_budget_exhausted: request requires 3 tokens but the shared KV budget has no headroom"])
        XCTAssertEqual(engine.submittedCount, 1, "Tight shared cap refuses before backend submission")
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, UInt64(needed+99))
        engine.finishAll()
        for await event in stream { if case .error(let message) = event { XCTFail(message) } }
        await bridge.shutdown()
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 99)
        await budget.release(requestID: "other-owner")
        XCTAssertEqual(budget.processLedger.snapshot().chargedBytes, 0)
    }

    func testActualMakeBridgeNilResolutionPreservesLegacyScalarsAndRounding() async throws {
        let engine = MTPAdmissionHeldEngine()
        let bridge = try EngineV2Factory.makeBridge(modelId: "legacy-admission-fixture",
            tokenizer: TokenizerHandle(MTPAdmissionTokenizer()), eosTokenIds: [],
            kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
            auxiliaryTokenGranularity: 256, auxiliaryTokenAllocationPadding: 7,
            makeEngine: { .init(engine: engine, fixedRequestBytes: 80, kvBackendKind: .contiguous,
                               kvBackendFallbackReason: nil, legacyMTPBytesPerToken: 20) })
        for count in counts {
            let bytes = await bridge.requestReservationBytes(tokenCount: count)
            XCTAssertEqual(bytes, 100*count + ((count+7+255)/256)*256*20 + 80)
        }
        XCTAssertEqual(engine.submittedCount, 0)
        await bridge.shutdown()
    }

    func testActualMakeBridgeUnavailableRefusalClosesBothPrefixStoresBeforePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtp-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(data: Data(repeating: 0x5a, count: 32)) // synthetic fixture only; no keychain
        let legacy = SSDPrefixCache(config: .init(modelId: "fixture", promptContractID: "fixture-prompt",
            weightHash: "fixture-weights", blockSize: 256, adoptionBoundTokens: 0,
            layoutEpoch: "fixture-layout", root: root.appendingPathComponent("legacy"),
            ttlSeconds: 60, minEffectiveTokens: 1, maxStageBytes: 1 << 20, maxStageMillis: 100,
            nowSeconds: { 1 }), kekKey: key, kvBudget: nil, diskBudget: SSDDiskBudget(), diskBudgetBytes: { 1 << 20 })
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "fixture-weights",
            promptContractID: "fixture-prompt", buildID: "fixture-build", numericsFingerprint: "fixture-numerics")
        let complete = SSDHybridCheckpointStore(config: .init(modelId: "fixture", identity: identity,
            root: root.appendingPathComponent("complete"), dedicatedRoot: root, epochStore: nil,
            maxReadBytes: 1 << 20, maxStageMillis: 100, minEffectiveTokens: 1, ttlSeconds: 60,
            strictFsync: false, nowSeconds: { 1 }, diskBudgetBytes: { 1 << 20 }, maintainWholeRoot: {}),
            kekKey: key, kvBudget: nil, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 20)
        let telemetry = MTPAdmissionTelemetry(), engine = MTPAdmissionHeldEngine()
        XCTAssertFalse(legacy.isClosed);XCTAssertFalse(complete.isClosed)
        var published: EngineV2Bridge?
        do {
            published = try EngineV2Factory.makeBridge(modelId: "refused-admission-fixture",
                tokenizer: TokenizerHandle(MTPAdmissionTokenizer()), eosTokenIds: [],
                kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
                ssdPrefixCache: legacy, ssdHybridCheckpointStore: complete,
                emitTelemetry: { telemetry.record($0) }, makeEngine: {
                    .init(engine: engine, fixedRequestBytes: Int.max, kvBackendKind: .contiguous,
                        kvBackendFallbackReason: nil, mtpAdmissionResolution: .unavailable(.allocatorPolicyUnavailable),
                        legacyMTPBytesPerToken: 20)
                })
            XCTFail("Unavailable declaration published a bridge")
        } catch { XCTAssertEqual(error as? CBv2MTPAdmissionRefusal, .allocatorPolicyUnavailable) }
        XCTAssertNil(published);XCTAssertEqual(engine.submittedCount, 0)
        XCTAssertTrue(legacy.isClosed);XCTAssertTrue(complete.isClosed)
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertEqual(telemetry.events.first?.severity, .error)
        XCTAssertEqual(telemetry.events.first?.fields?["operation"]?.description, "engine_v2_refusal")
        XCTAssertEqual(telemetry.events.first?.fields?["reason"]?.description, "engine_init_failed")
        if let published { await published.shutdown() }
        await legacy.closeAndWait();await complete.closeAndWait()
    }

    func testActualMakeBridgeRejectsInconsistentFixedChargeBeforeSuccessTelemetry() async throws {
        let engine = MTPAdmissionHeldEngine(), telemetry = MTPAdmissionTelemetry()
        var published: EngineV2Bridge?
        do {
            published = try EngineV2Factory.makeBridge(modelId: "inconsistent-admission-fixture",
                tokenizer: TokenizerHandle(MTPAdmissionTokenizer()), eosTokenIds: [],
                kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
                emitTelemetry: { telemetry.record($0) }, makeEngine: {
                    .init(engine: engine, fixedRequestBytes: 319, kvBackendKind: .contiguous,
                        kvBackendFallbackReason: nil, mtpAdmissionResolution: self.bounded, legacyMTPBytesPerToken: 20)
                })
            XCTFail("Incomplete fixed charge published a bridge")
        } catch { XCTAssertEqual(error as? CBv2MTPAdmissionRefusal, .invalidExistingCharge) }
        XCTAssertNil(published);XCTAssertEqual(engine.submittedCount, 0)
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertEqual(telemetry.events.first?.fields?["operation"]?.description, "engine_v2_refusal")
        if let published { await published.shutdown() }
    }
}

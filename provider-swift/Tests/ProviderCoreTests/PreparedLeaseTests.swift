// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private func preparedUUID(_ value: UInt64) -> ProtocolV2UUID {
    ProtocolV2UUID(String(format: "00000000-0000-0000-0000-%012llx", value))!
}

private func preparedIdentity(
    provider: UInt64 = 1,
    process: UInt64 = 2,
    session: UInt64 = 3,
    request: UInt64 = 4,
    attempt: UInt64 = 5,
    reservation: UInt64 = 6,
    lease: UInt64 = 7
) -> AttemptIdentity {
    AttemptIdentity(
        providerID: preparedUUID(provider),
        providerProcessGeneration: preparedUUID(process),
        sessionEpoch: session,
        requestID: preparedUUID(request),
        attemptID: preparedUUID(attempt),
        reservationID: preparedUUID(reservation),
        leaseID: preparedUUID(lease))
}

private actor PreparedCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private actor PreparedGate {
    private var isOpen = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func operation() async {
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if !openWaiters.isEmpty || isOpen { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor PreparedCallProbe {
    private var entered = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func finish() { completed = true }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func isCompleted() -> Bool { completed }
}

private actor ScriptedPreparedExecutor: PreparedInferenceExecutor {
    private var prepared: [LeaseID: PreparedInference] = [:]
    private var continuations: [LeaseID: AsyncStream<GenerationEvent>.Continuation] = [:]
    private var completions: [LeaseID: PreparedInferenceCompletion] = [:]
    private var prepareCallsValue = 0
    private var startCallsValue = 0
    private var abortCallsValue = 0
    private var cancelCallsValue = 0
    private var forceCallsValue = 0
    private let wedgeCancel: Bool
    private let blockStart: Bool
    private var startGate: CheckedContinuation<Void, Never>?
    private var startObservedWaiters: [CheckedContinuation<Void, Never>] = []

    init(wedgeCancel: Bool = false, blockStart: Bool = false) {
        self.wedgeCancel = wedgeCancel
        self.blockStart = blockStart
    }

    func prepareInference(
        _ inference: PreparedInference,
        expiresAt: Date
    ) async throws -> PreparedInferenceAdmission {
        prepareCallsValue += 1
        prepared[inference.identity.leaseID] = inference
        return PreparedInferenceAdmission(
            promptTokens: inference.promptTokens.count,
            maxOutputTokens: inference.facts.maxOutputTokens,
            engineQueueDepth: 0,
            reservedKVBytes: UInt64(inference.promptTokens.count),
            reservedMediaBytes: inference.facts.mediaBytes,
            prefillCanBegin: false,
            estimatedPrefillMilliseconds: nil)
    }

    func startPreparedInference(
        identity: AttemptIdentity
    ) async throws -> PreparedInferenceExecution {
        startCallsValue += 1
        let observed = startObservedWaiters
        startObservedWaiters.removeAll()
        for waiter in observed { waiter.resume() }
        guard let inference = prepared[identity.leaseID] else {
            throw PreparedInferenceAdmissionError.unknownLease
        }
        guard inference.identity == identity else {
            throw PreparedInferenceAdmissionError.identityConflict
        }
        if blockStart {
            await withCheckedContinuation { startGate = $0 }
        }
        let completion = PreparedInferenceCompletion()
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
        continuations[identity.leaseID] = continuation
        completions[identity.leaseID] = completion
        return PreparedInferenceExecution(events: stream, completion: completion)
    }

    func abortPreparedInference(identity: AttemptIdentity) async {
        abortCallsValue += 1
        guard let inference = prepared[identity.leaseID],
            inference.identity == identity
        else { return }
        prepared.removeValue(forKey: identity.leaseID)
        await inference.resourceRelease.fire()
    }

    func cancelPreparedInference(identity: AttemptIdentity) async {
        cancelCallsValue += 1
        guard let inference = prepared[identity.leaseID],
            inference.identity == identity
        else { return }
        if wedgeCancel { return }
        continuations.removeValue(forKey: identity.leaseID)?.finish()
        await completions.removeValue(forKey: identity.leaseID)?.finish()
        prepared.removeValue(forKey: identity.leaseID)
        await inference.resourceRelease.fire()
    }

    func forceReleasePreparedInference(identity: AttemptIdentity) async {
        forceCallsValue += 1
        startGate?.resume()
        startGate = nil
        continuations.removeValue(forKey: identity.leaseID)?.finish()
        await completions.removeValue(forKey: identity.leaseID)?.finish()
        guard let inference = prepared[identity.leaseID],
            inference.identity == identity
        else { return }
        prepared.removeValue(forKey: identity.leaseID)
        await inference.resourceRelease.fire()
    }

    func waitUntilStartCalled() async {
        if startCallsValue > 0 { return }
        await withCheckedContinuation { startObservedWaiters.append($0) }
    }

    func counts() -> (prepare: Int, start: Int, abort: Int, cancel: Int, force: Int) {
        (
            prepareCallsValue,
            startCallsValue,
            abortCallsValue,
            cancelCallsValue,
            forceCallsValue
        )
    }
}

private func preparedInference(
    identity: AttemptIdentity = preparedIdentity(),
    digest: String = "digest-1",
    modelID: String = "test-model",
    promptTokens: [Int] = [1, 2],
    maxOutputTokens: Int = 2,
    release: PreparedInferenceResourceRelease = PreparedInferenceResourceRelease()
) throws -> PreparedInference {
    try PreparedInference(
        identity: identity,
        requestDigest: digest,
        modelID: modelID,
        promptTokens: promptTokens,
        request: ChatCompletionRequest(
            model: modelID,
            messages: [ChatMessage(role: "user", content: "hello")],
            max_tokens: maxOutputTokens),
        facts: PreparedInferenceFacts(
            decryptionComplete: true,
            renderingComplete: true,
            tokenizationComplete: true,
            promptTokens: promptTokens.count,
            maxOutputTokens: maxOutputTokens),
        resourceRelease: release)
}

private final class PreparedAdmissionEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let layerKinds: [CBv2LayerKind]
    private let config: AdmissionV2.Config
    private let externalReserveBytes: Int
    private var capacityValue: Int
    private var submittedValue = 0
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []

    init(
        capacity: Int,
        layerKinds: [CBv2LayerKind],
        config: AdmissionV2.Config,
        externalReserveBytes: Int
    ) {
        capacityValue = capacity
        self.layerKinds = layerKinds
        self.config = config
        self.externalReserveBytes = externalReserveBytes
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let accepted = lock.withLock {
            AdmissionV2(
                layerKinds: layerKinds,
                bytesCapacity: capacityValue,
                config: config,
                externalReserveBytes: externalReserveBytes
            ).canEverFit(
                promptTokens: request.promptTokens.count,
                maxTokens: request.maxTokens)
        }
        guard accepted else {
            throw CBv2KVError.capacityExhausted(needed: 1, available: 0)
        }
        lock.withLock { submittedValue += 1 }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { continuations.append(continuation) }
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: submittedValue,
                waitingRequests: 0,
                kvBytesInUse: 0,
                kvBytesCapacity: capacityValue,
                activeTokens: 0)
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock { capacityValue = bytes }
    }

    func shutdown() async {}

    var submitted: Int { lock.withLock { submittedValue } }
    var currentCapacity: Int { lock.withLock { capacityValue } }
}

private func preparedBridge(
    engine: any CBv2Engine,
    admission: EngineV2PreparedAdmission,
    maxConcurrentRequests: Int = 4
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: "test-model",
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        eosTokenIds: [],
        maxConcurrentRequests: maxConcurrentRequests,
        kvBytesPerToken: 4,
        preparedAdmission: admission)
}

private let preparedLayer = CBv2LayerKind(
    attention: .full,
    headDim: 1,
    kvHeads: 1,
    queryHeads: 1)

@Suite("Prepared lease execution primitives")
struct PreparedLeaseTests {
    @Test("every AttemptIdentity field is part of the lease binding")
    func fullIdentityConflicts() async throws {
        let manager = PreparedLeaseManager(automaticallyExpire: false)
        let executor = ScriptedPreparedExecutor()
        let identity = preparedIdentity()
        _ = try await manager.prepare(
            inference: preparedInference(identity: identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor)

        let conflicts = [
            preparedIdentity(provider: 11),
            preparedIdentity(process: 12),
            preparedIdentity(session: 13),
            preparedIdentity(request: 14),
            preparedIdentity(attempt: 15),
            preparedIdentity(reservation: 16),
        ]
        for conflict in conflicts {
            await #expect(throws: PreparedLeaseError.identityConflict) {
                _ = try await manager.prepare(
                    inference: preparedInference(identity: conflict),
                    expiresAt: Date().addingTimeInterval(60),
                    using: executor)
            }
            #expect(await manager.abort(identity: conflict) == .identityConflict)
            await #expect(throws: PreparedLeaseError.identityConflict) {
                _ = try await manager.start(identity: conflict)
            }
        }

        await #expect(throws: PreparedLeaseError.conflictingDuplicate) {
            _ = try await manager.prepare(
                inference: preparedInference(identity: identity, digest: "different"),
                expiresAt: Date().addingTimeInterval(60),
                using: executor)
        }
        await #expect(throws: PreparedLeaseError.conflictingDuplicate) {
            _ = try await manager.prepare(
                inference: preparedInference(identity: identity, modelID: "other-model"),
                expiresAt: Date().addingTimeInterval(60),
                using: executor)
        }
        #expect(await executor.counts().prepare == 1)
    }

    @Test("bridge controls validate full identity before touching reservations")
    func bridgeIdentityConflicts() async throws {
        let config = AdmissionV2.Config(watermarkFraction: 0)
        let profile = EngineV2PreparedAdmission(
            layerKinds: [preparedLayer],
            config: config)
        let engine = PreparedAdmissionEngine(
            capacity: 1_000,
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 0)
        let bridge = preparedBridge(engine: engine, admission: profile)
        let identity = preparedIdentity(lease: 21)
        let inference = try preparedInference(identity: identity)
        _ = try await bridge.prepareInference(
            inference,
            expiresAt: Date().addingTimeInterval(60))

        let conflict = preparedIdentity(provider: 99, lease: 21)
        await #expect(throws: PreparedInferenceAdmissionError.identityConflict) {
            _ = try await bridge.prepareInference(
                preparedInference(identity: conflict),
                expiresAt: Date().addingTimeInterval(60))
        }
        await #expect(throws: PreparedInferenceAdmissionError.identityConflict) {
            _ = try await bridge.startPreparedInference(identity: conflict)
        }
        await bridge.abortPreparedInference(identity: conflict)

        #expect(engine.submitted == 0)
        _ = try await bridge.startPreparedInference(identity: identity)
        #expect(engine.submitted == 1)
        await bridge.forceReleasePreparedInference(identity: identity)
    }

    @Test("duplicate prepare and controls remain idempotent")
    func duplicatePrepareAndAbort() async throws {
        let manager = PreparedLeaseManager(automaticallyExpire: false)
        let executor = ScriptedPreparedExecutor()
        let identity = preparedIdentity()
        let first = try await manager.prepare(
            inference: preparedInference(identity: identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor)
        let duplicate = try await manager.prepare(
            inference: preparedInference(identity: identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor)

        #expect(first == duplicate)
        #expect(await executor.counts().prepare == 1)
        #expect(await manager.abort(identity: identity) == .aborted)
        #expect(await manager.abort(identity: identity) == .alreadyAborted)
        #expect(await executor.counts().abort == 1)
    }

    @Test("reported duplicate TTL is bounded by absolute lease expiry")
    func remainingLeaseTTL() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let inference = try preparedInference(identity: preparedIdentity())
        let lease = PreparedLease(
            inference: inference,
            expiresAt: now.addingTimeInterval(10),
            now: now,
            admission: PreparedInferenceAdmission(
                promptTokens: inference.facts.promptTokens,
                maxOutputTokens: inference.facts.maxOutputTokens,
                engineQueueDepth: 0,
                reservedKVBytes: 0,
                reservedMediaBytes: 0,
                prefillCanBegin: false,
                estimatedPrefillMilliseconds: nil
            )
        )

        #expect(lease.leaseTTLMilliseconds == 10_000)
        #expect(
            lease.remainingTTLMilliseconds(
                at: now.addingTimeInterval(3)) == 7_000)
        #expect(
            lease.remainingTTLMilliseconds(
                at: now.addingTimeInterval(11)) == 0)
    }

    @Test("resource release concurrent callers join the single operation")
    func releaseIsJoinableExactlyOnce() async {
        let gate = PreparedGate()
        let count = PreparedCounter()
        let release = PreparedInferenceResourceRelease {
            await count.increment()
            await gate.operation()
        }
        let first = Task { await release.fire() }
        await gate.waitUntilStarted()

        let secondProbe = PreparedCallProbe()
        let second = Task {
            await secondProbe.enter()
            await release.fire()
            await secondProbe.finish()
        }
        await secondProbe.waitUntilEntered()
        #expect(await secondProbe.isCompleted() == false)
        #expect(await count.count() == 1)

        await gate.open()
        await first.value
        await second.value
        #expect(await secondProbe.isCompleted())
        #expect(await count.count() == 1)
        #expect(await release.hasFiredForTesting())
    }

    @Test("wedged cancel times out, force releases, and fails closed")
    func cancelTimeoutEscalates() async throws {
        let identity = preparedIdentity()
        let releaseCount = PreparedCounter()
        let manager = PreparedLeaseManager(
            automaticallyExpire: false,
            terminalWaitTimeout: .milliseconds(20))
        let executor = ScriptedPreparedExecutor(wedgeCancel: true)
        _ = try await manager.prepare(
            inference: preparedInference(
                identity: identity,
                release: PreparedInferenceResourceRelease {
                    await releaseCount.increment()
                }),
            expiresAt: Date().addingTimeInterval(60),
            using: executor)
        _ = try await manager.start(identity: identity)

        #expect(await manager.cancel(identity: identity) == .failed)
        #expect(await manager.state(of: identity) == .failed)
        #expect(await executor.counts().cancel == 1)
        #expect(await executor.counts().force == 1)
        #expect(await releaseCount.count() == 1)
    }

    @Test("abort does not wait forever for a wedged start transition")
    func abortTimeoutDuringStart() async throws {
        let identity = preparedIdentity(request: 104, lease: 101)
        let releaseCount = PreparedCounter()
        let manager = PreparedLeaseManager(
            automaticallyExpire: false,
            terminalWaitTimeout: .milliseconds(20))
        let executor = ScriptedPreparedExecutor(blockStart: true)
        _ = try await manager.prepare(
            inference: preparedInference(
                identity: identity,
                release: PreparedInferenceResourceRelease {
                    await releaseCount.increment()
                }),
            expiresAt: Date().addingTimeInterval(60),
            using: executor)

        let start = Task { try await manager.start(identity: identity) }
        await executor.waitUntilStartCalled()
        #expect(await manager.abort(identity: identity) == .failed)
        #expect(await manager.state(of: identity) == .failed)
        await #expect(throws: PreparedLeaseError.self) {
            _ = try await start.value
        }
        #expect(await executor.counts().force >= 1)
        #expect(await releaseCount.count() == 1)
    }

    @Test("bridge force release frees local state and refuses new admissions")
    func bridgeForceReleaseFailsClosed() async throws {
        let config = AdmissionV2.Config(watermarkFraction: 0)
        let profile = EngineV2PreparedAdmission(
            layerKinds: [preparedLayer],
            config: config)
        let engine = PreparedAdmissionEngine(
            capacity: 1_000,
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 0)
        let bridge = preparedBridge(engine: engine, admission: profile)
        let releaseCount = PreparedCounter()
        let inference = try preparedInference(
            identity: preparedIdentity(request: 94, lease: 91),
            release: PreparedInferenceResourceRelease {
                await releaseCount.increment()
            })
        _ = try await bridge.prepareInference(
            inference,
            expiresAt: Date().addingTimeInterval(60))
        _ = try await bridge.startPreparedInference(identity: inference.identity)

        await bridge.forceReleasePreparedInference(identity: inference.identity)
        #expect(await releaseCount.count() == 1)
        #expect(await bridge.backendSlotCapacity().state == "crashed")
        await #expect(throws: PreparedInferenceAdmissionError.engineTerminalWedge) {
            _ = try await bridge.prepareInference(
                preparedInference(identity: preparedIdentity(request: 95, lease: 92)),
                expiresAt: Date().addingTimeInterval(60))
        }
    }

    @Test("prepared profile exactly matches AdmissionV2")
    func exactAdmissionParity() {
        let layers = [
            CBv2LayerKind(
                attention: .full, headDim: 3, kvHeads: 2, queryHeads: 4),
            CBv2LayerKind(
                attention: .slidingWindow(5), headDim: 2, kvHeads: 1, queryHeads: 2),
            CBv2LayerKind(
                attention: .full, sharesKVWithLayer: 0,
                headDim: 3, kvHeads: 2, queryHeads: 4),
        ]
        let config = AdmissionV2.Config(
            watermarkFraction: 0.125,
            elementBytes: 2,
            layerElementBytes: [4, 2, 8])
        let capacity = 12_345
        let externalReserve = 321
        let engineAdmission = AdmissionV2(
            layerKinds: layers,
            bytesCapacity: capacity,
            config: config,
            externalReserveBytes: externalReserve)
        let preparedAdmission = EngineV2PreparedAdmission(
            layerKinds: layers,
            config: config,
            externalReserveBytes: externalReserve)

        #expect(
            preparedAdmission.admissibleBytesCapacity(totalCapacity: capacity)
                == engineAdmission.admissibleBytesCapacity)
        for tokens in [0, 1, 4, 5, 6, 32, 4_096] {
            #expect(
                preparedAdmission.estimatedBytes(forTokens: tokens)
                    == UInt64(engineAdmission.estimatedBytes(forTokens: tokens)))
            #expect(
                (Int(preparedAdmission.estimatedBytes(forTokens: tokens)!)
                    <= preparedAdmission.admissibleBytesCapacity(totalCapacity: capacity))
                    == engineAdmission.canEverFit(promptTokens: tokens, maxTokens: 0))
        }
    }

    @Test("compiled reserve is included at the exact admission boundary")
    func compiledReserveBoundary() async throws {
        let config = AdmissionV2.Config(watermarkFraction: 0.10)
        let profile = EngineV2PreparedAdmission(
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 20)
        #expect(profile.admissibleBytesCapacity(totalCapacity: 100) == 70)
        #expect(profile.estimatedBytes(forTokens: 17) == 68)
        #expect(profile.estimatedBytes(forTokens: 18) == 72)

        let acceptingEngine = PreparedAdmissionEngine(
            capacity: 100,
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 20)
        // Production factory returns this metadata-carrying wrapper; the
        // bridge must discover the profile without a second hand-wired value.
        let acceptingBridge = EngineV2Bridge(
            engine: PreparedAdmissionCBv2Engine(
                engine: acceptingEngine,
                preparedAdmission: profile),
            modelId: "test-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            eosTokenIds: [],
            kvBytesPerToken: 4)
        #expect(await acceptingBridge.backendSlotCapacity().activeTokenBudgetMax == 17)
        let accepted = try preparedInference(
            identity: preparedIdentity(lease: 71),
            promptTokens: Array(repeating: 1, count: 16),
            maxOutputTokens: 1)
        let admission = try await acceptingBridge.prepareInference(
            accepted,
            expiresAt: Date().addingTimeInterval(60))
        #expect(admission.reservedKVBytes == 68)
        #expect(admission.prefillCanBegin == false)
        await acceptingBridge.abortPreparedInference(identity: accepted.identity)

        let rejectingEngine = PreparedAdmissionEngine(
            capacity: 100,
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 20)
        let rejectingBridge = preparedBridge(engine: rejectingEngine, admission: profile)
        let rejected = try preparedInference(
            identity: preparedIdentity(request: 74, lease: 72),
            promptTokens: Array(repeating: 1, count: 17),
            maxOutputTokens: 1)
        await #expect(
            throws: PreparedInferenceAdmissionError.kvCapacityExhausted(
                needed: 72, available: 70)
        ) {
            _ = try await rejectingBridge.prepareInference(
                rejected,
                expiresAt: Date().addingTimeInterval(60))
        }
    }

    @Test("prepare and start retain one KV ceiling across a re-slice")
    func prepareStartAdmissionCeilingParity() async throws {
        let config = AdmissionV2.Config(watermarkFraction: 0.10)
        let profile = EngineV2PreparedAdmission(
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 20)
        let engine = PreparedAdmissionEngine(
            capacity: 100,
            layerKinds: [preparedLayer],
            config: config,
            externalReserveBytes: 20)
        let bridge = preparedBridge(engine: engine, admission: profile)
        let inference = try preparedInference(
            identity: preparedIdentity(request: 84, lease: 81),
            promptTokens: Array(repeating: 1, count: 16),
            maxOutputTokens: 1)

        _ = try await bridge.prepareInference(
            inference,
            expiresAt: Date().addingTimeInterval(60))
        #expect(engine.submitted == 0)
        await bridge.updateKVBytesCapacity(80)
        #expect(engine.currentCapacity == 100)

        _ = try await bridge.startPreparedInference(identity: inference.identity)
        #expect(engine.submitted == 1)
        #expect(engine.currentCapacity == 80)
        await bridge.forceReleasePreparedInference(identity: inference.identity)
    }
}

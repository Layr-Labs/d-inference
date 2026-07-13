import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private struct V2AttemptTestKeySource: ProviderJournalKeySource {
    let key: SymmetricKey
    func loadOrCreateKey() throws -> SymmetricKey { key }
}

private struct V2AttemptTestSigner: TerminalDigestSigner {
    let key = P256.Signing.PrivateKey()

    var publicKeyBase64: String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func signTerminalDigest(_ digest: TerminalDigest) throws -> Data {
        try key.signature(for: digest.bytes).derRepresentation
    }
}

private enum V2AttemptTestSignerError: Error {
    case unavailable
}

private actor V2AttemptReleaseCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private struct V2AttemptFailingSigner: TerminalDigestSigner {
    let key = P256.Signing.PrivateKey()

    var publicKeyBase64: String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func signTerminalDigest(_: TerminalDigest) throws -> Data {
        throw V2AttemptTestSignerError.unavailable
    }
}

private actor V2AttemptTestExecutor: PreparedInferenceExecutor {
    private let durableRoot: URL
    private var prepared: [LeaseID: PreparedInference] = [:]
    private var continuations: [LeaseID: AsyncStream<GenerationEvent>.Continuation] = [:]
    private var completions: [LeaseID: PreparedInferenceCompletion] = [:]
    private var startCallsValue = 0
    private var durableStartObservedValue = false

    init(durableRoot: URL) {
        self.durableRoot = durableRoot
    }

    func prepareInference(
        _ inference: PreparedInference,
        expiresAt _: Date
    ) async throws -> PreparedInferenceAdmission {
        prepared[inference.identity.leaseID] = inference
        return PreparedInferenceAdmission(
            promptTokens: inference.promptTokens.count,
            maxOutputTokens: inference.facts.maxOutputTokens,
            engineQueueDepth: 0,
            reservedKVBytes: 1_024,
            reservedMediaBytes: 0,
            prefillCanBegin: false,
            estimatedPrefillMilliseconds: nil
        )
    }

    func startPreparedInference(
        identity: AttemptIdentity
    ) async throws -> PreparedInferenceExecution {
        startCallsValue += 1
        let records =
            durableRoot
            .appendingPathComponent("terminals/records", isDirectory: true)
        durableStartObservedValue =
            ((try? FileManager.default.contentsOfDirectory(
                at: records,
                includingPropertiesForKeys: nil
            ))?.contains(where: { $0.pathExtension == "dbtj" })) == true
        guard let inference = prepared[identity.leaseID],
            inference.identity == identity
        else {
            throw PreparedInferenceAdmissionError.unknownLease
        }
        let completion = PreparedInferenceCompletion()
        let (events, continuation) = AsyncStream<GenerationEvent>.makeStream()
        continuations[identity.leaseID] = continuation
        completions[identity.leaseID] = completion
        return PreparedInferenceExecution(events: events, completion: completion)
    }

    func abortPreparedInference(identity: AttemptIdentity) async {
        guard let inference = prepared.removeValue(forKey: identity.leaseID),
            inference.identity == identity
        else { return }
        await inference.resourceRelease.fire()
    }

    func cancelPreparedInference(identity: AttemptIdentity) async {
        guard let inference = prepared.removeValue(forKey: identity.leaseID),
            inference.identity == identity
        else { return }
        if let continuation = continuations.removeValue(forKey: identity.leaseID) {
            continuation.yield(.error("request cancelled"))
            continuation.finish()
        }
        await completions.removeValue(forKey: identity.leaseID)?.finish()
        await inference.resourceRelease.fire()
    }

    func forceReleasePreparedInference(identity: AttemptIdentity) async {
        await cancelPreparedInference(identity: identity)
    }

    func finish(identity: AttemptIdentity) async {
        continuations.removeValue(forKey: identity.leaseID)?.finish()
        await completions.removeValue(forKey: identity.leaseID)?.finish()
        if let inference = prepared.removeValue(forKey: identity.leaseID),
            inference.identity == identity
        {
            await inference.resourceRelease.fire()
        }
    }

    func startCalls() -> Int { startCallsValue }
    func durableStartObserved() -> Bool { durableStartObservedValue }
}

@Suite("Protocol v2 composed paid-attempt lifecycle")
struct V2PreparedAttemptCoordinatorTests {
    @Test("attempt reconciliation reports exact prepared, started, terminal, and tombstoned state")
    func attemptReconciliationStates() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        #expect(
            try await fixture.coordinator.attemptStatus(identity: fixture.identity).state
                == .unknown)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        #expect(
            try await fixture.coordinator.attemptStatus(identity: fixture.identity).state
                == .prepared)
        _ = try await fixture.coordinator.start(identity: fixture.identity)
        #expect(
            try await fixture.coordinator.attemptStatus(identity: fixture.identity).state
                == .started)
        _ = try await fixture.coordinator.cancel(identity: fixture.identity)
        let frozen = try await fixture.coordinator.persistTerminal(
            identity: fixture.identity,
            draft: ProviderTerminalDraft(
                outcome: .cancelled,
                errorClass: .cancelled,
                completionTokens: 0,
                responseHash: .sha256(Data()),
                finalGeneratedTokens: 0,
                rollingDigest: .zero
            )
        )
        let terminal = try await fixture.coordinator.attemptStatus(
            identity: fixture.identity)
        #expect(terminal.state == .terminal)
        #expect(terminal.terminalDigest == frozen.protocolV2.terminalDigest)

        let tombstoned = v2AttemptIdentity(attempt: 45, request: 44, lease: 47)
        _ = try await fixture.coordinator.abort(
            identity: tombstoned,
            reason: "crash_before_start"
        )
        #expect(
            try await fixture.coordinator.attemptStatus(identity: tombstoned).state
                == .unknown)

        let expired = v2AttemptIdentity(attempt: 48, request: 49, lease: 50)
        _ = try await fixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: expired),
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        await fixture.manager.expireLeases(at: Date().addingTimeInterval(120))
        #expect(
            try await fixture.coordinator.attemptStatus(identity: expired).state
                == .unknown)
    }

    @Test("funded start is durable before executor submission")
    func durableStartBeforeSubmit() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        #expect(await executor.startCalls() == 0)
        #expect(await fixture.coordinator.durableStart(for: fixture.identity) == nil)

        guard
            case .started = try await fixture.coordinator.start(
                identity: fixture.identity)
        else {
            Issue.record("first start did not submit")
            return
        }
        #expect(await executor.startCalls() == 1)
        #expect(await executor.durableStartObserved())
        #expect(await fixture.coordinator.durableStart(for: fixture.identity) != nil)
    }

    @Test("durable abort wins over delayed start")
    func abortWinsDelayedStart() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        #expect(
            try await fixture.coordinator.abort(
                identity: fixture.identity, reason: "coordinator_reordered")
                == .aborted)
        await #expect(throws: AttemptTombstoneError.self) {
            _ = try await fixture.coordinator.start(identity: fixture.identity)
        }
        #expect(await executor.startCalls() == 0)
        #expect(await fixture.coordinator.durableStart(for: fixture.identity) == nil)
    }

    @Test("abort received before prepare durably fences admission")
    func abortBeforePrepareWins() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        #expect(
            try await fixture.coordinator.abort(
                identity: fixture.identity, reason: "abort_before_prepare")
                == .aborted)
        await #expect(throws: AttemptTombstoneError.self) {
            _ = try await fixture.coordinator.prepare(
                inference: makeV2AttemptInference(identity: fixture.identity),
                expiresAt: Date().addingTimeInterval(60),
                using: executor
            )
        }
        #expect(await executor.startCalls() == 0)
        #expect(await fixture.manager.liveLeaseCount() == 0)
    }

    @Test("duplicate start stays idempotent after engine completion")
    func duplicateStartAfterCompletion() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        guard
            case .started = try await fixture.coordinator.start(
                identity: fixture.identity)
        else {
            Issue.record("first start did not submit")
            return
        }
        await executor.finish(identity: fixture.identity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await fixture.manager.state(of: fixture.identity) != .completed,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.manager.state(of: fixture.identity) == .completed)
        #expect(
            try await fixture.coordinator.preparedLease(
                identity: fixture.identity,
                requestDigest: inference.requestDigest,
                modelID: inference.modelID
            ) != nil
        )
        guard
            case .alreadyStarted = try await fixture.coordinator.start(
                identity: fixture.identity)
        else {
            Issue.record("duplicate funded start was not idempotent")
            return
        }
        #expect(await executor.startCalls() == 1)
    }

    @Test("attempt identity collision across lease IDs is rejected at prepare")
    func attemptCollisionAcrossLeases() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: fixture.identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        let conflicting = v2AttemptIdentity(
            attempt: 5,
            request: 4,
            lease: 99
        )
        await #expect(
            throws: V2PreparedAttemptCoordinatorError.identityConflict
        ) {
            _ = try await fixture.coordinator.prepare(
                inference: makeV2AttemptInference(identity: conflicting),
                expiresAt: Date().addingTimeInterval(60),
                using: executor
            )
        }
        #expect(await fixture.manager.liveLeaseCount() == 1)
    }

    @Test("cancelled started work freezes before replay and exact ACK deletes")
    func cancelTerminalReplayAndAck() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: fixture.identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        _ = try await fixture.coordinator.start(identity: fixture.identity)
        #expect(
            try await fixture.coordinator.cancel(identity: fixture.identity)
                == .cancelled)

        let frozen = try await fixture.coordinator.persistTerminal(
            identity: fixture.identity,
            draft: ProviderTerminalDraft(
                outcome: .cancelled,
                errorClass: .cancelled,
                completionTokens: 0,
                responseHash: .sha256(Data()),
                finalGeneratedTokens: 0,
                rollingDigest: .zero
            )
        )
        #expect(await fixture.coordinator.pendingTerminalCount() == 1)
        #expect(try await fixture.coordinator.pendingHistoricalReplays().count == 1)

        var conflicting = frozen.protocolV2.terminalDigest
        conflicting = ProtocolV2Digest(
            bytes: Data(repeating: 0xAA, count: 32))!
        await #expect(throws: V2PreparedAttemptCoordinatorError.terminalAckConflict) {
            try await fixture.coordinator.acknowledge(
                V2TerminalAck(
                    identity: fixture.identity,
                    terminalDigest: conflicting,
                    disposition: .conflict
                ))
        }
        #expect(await fixture.coordinator.pendingTerminalCount() == 1)

        try await fixture.coordinator.acknowledge(
            V2TerminalAck(
                identity: fixture.identity,
                terminalDigest: frozen.protocolV2.terminalDigest,
                disposition: .settled
            ))
        #expect(await fixture.coordinator.pendingTerminalCount() == 0)
    }

    @Test("failed start ACK quiesces work and freezes zero delivered usage")
    func failedStartAckFreezesZeroDeliveryTerminal() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: fixture.identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        _ = try await fixture.coordinator.start(identity: fixture.identity)

        let frozen = try await fixture.coordinator.cancelUndeliveredStart(
            identity: fixture.identity)
        #expect(frozen.terminal.outcome == .cancelled)
        #expect(frozen.terminal.completionTokens == 0)
        #expect(frozen.terminal.finalGeneratedTokens == 0)
        #expect(frozen.terminal.responseHash == .sha256(Data()))
        #expect(frozen.terminal.rollingDigest == .zero)
        #expect(await fixture.coordinator.pendingTerminalCount() == 1)
        #expect(await fixture.coordinator.durableStart(for: fixture.identity) == nil)
    }

    @Test("expired bindings cannot replay a stale prepared lease")
    func expiredBindingIsNotPrepared() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        await fixture.manager.expireLeases(
            at: Date().addingTimeInterval(120))

        await #expect(throws: PreparedLeaseError.expired) {
            _ = try await fixture.coordinator.preparedLease(
                identity: fixture.identity,
                requestDigest: inference.requestDigest,
                modelID: inference.modelID
            )
        }
    }

    @Test("maintenance drops decrypted prepare binding after lease expiry")
    func prepareWithoutStartReleasesBindingAfterExpiry() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let releases = V2AttemptReleaseCounter()
        let inference = try makeV2AttemptInference(
            identity: fixture.identity,
            resourceRelease: PreparedInferenceResourceRelease {
                await releases.increment()
            }
        )
        let expiresAt = Date().addingTimeInterval(10)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: expiresAt,
            using: executor
        )
        #expect(await fixture.coordinator.bindingCountForTesting() == 1)
        #expect(await fixture.manager.liveLeaseCount() == 1)

        #expect(
            await fixture.coordinator.reapTerminalBindings(
                at: expiresAt.addingTimeInterval(1)
            ) == 1)
        #expect(await fixture.coordinator.bindingCountForTesting() == 0)
        #expect(await fixture.manager.liveLeaseCount() == 0)
        #expect(await releases.count() == 1)
        await #expect(throws: PreparedLeaseError.expired) {
            _ = try await fixture.coordinator.preparedLease(
                identity: fixture.identity,
                requestDigest: inference.requestDigest,
                modelID: inference.modelID
            )
        }
    }

    @Test("maintenance follows independent manager abort")
    func independentManagerAbortDropsBinding() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let releases = V2AttemptReleaseCounter()
        let inference = try makeV2AttemptInference(
            identity: fixture.identity,
            resourceRelease: PreparedInferenceResourceRelease {
                await releases.increment()
            }
        )

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        #expect(await fixture.manager.abort(identity: fixture.identity) == .aborted)
        #expect(await fixture.coordinator.bindingCountForTesting() == 1)
        #expect(await fixture.coordinator.reapTerminalBindings() == 1)
        #expect(await fixture.coordinator.bindingCountForTesting() == 0)
        #expect(await releases.count() == 1)
    }

    @Test("maintenance drops completed binding without losing start idempotency")
    func independentManagerCompletionDropsBinding() async throws {
        let fixture = try makeV2AttemptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)
        let inference = try makeV2AttemptInference(identity: fixture.identity)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: inference,
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        _ = try await fixture.coordinator.start(identity: fixture.identity)
        await executor.finish(identity: fixture.identity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await fixture.manager.state(of: fixture.identity) != .completed,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await fixture.coordinator.reapTerminalBindings() == 1)
        #expect(await fixture.coordinator.bindingCountForTesting() == 0)
        guard
            case .alreadyStarted = try await fixture.coordinator.start(
                identity: fixture.identity)
        else {
            Issue.record("durable funded start lost idempotency after binding reap")
            return
        }
    }

    @Test("journal and tombstone capacity independently stop paid prepare")
    func combinedCapacityGate() async throws {
        let capacity = try TerminalJournalCapacity(
            maxEntries: 1,
            maxEncryptedRecordBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes,
            maxTotalReservedBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes
        )

        let journalFixture = try makeV2AttemptFixture(capacity: capacity)
        defer {
            try? FileManager.default.removeItem(at: journalFixture.directory)
        }
        let journalExecutor = V2AttemptTestExecutor(
            durableRoot: journalFixture.directory)
        _ = try await journalFixture.coordinator.activate(
            providerID: journalFixture.identity.providerID)
        _ = try await journalFixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: journalFixture.identity),
            expiresAt: Date().addingTimeInterval(60),
            using: journalExecutor
        )
        _ = try await journalFixture.coordinator.start(
            identity: journalFixture.identity)
        let nextIdentity = v2AttemptIdentity(attempt: 15, request: 14, lease: 17)
        await #expect(
            throws: V2PreparedAttemptCoordinatorError.paidAdmissionStopped
        ) {
            _ = try await journalFixture.coordinator.prepare(
                inference: makeV2AttemptInference(identity: nextIdentity),
                expiresAt: Date().addingTimeInterval(60),
                using: journalExecutor
            )
        }

        let tombstoneFixture = try makeV2AttemptFixture(capacity: capacity)
        defer {
            try? FileManager.default.removeItem(at: tombstoneFixture.directory)
        }
        let tombstoneExecutor = V2AttemptTestExecutor(
            durableRoot: tombstoneFixture.directory)
        _ = try await tombstoneFixture.coordinator.activate(
            providerID: tombstoneFixture.identity.providerID)
        _ = try await tombstoneFixture.coordinator.abort(
            identity: tombstoneFixture.identity,
            reason: "fill_tombstone_capacity"
        )
        await #expect(
            throws: V2PreparedAttemptCoordinatorError.paidAdmissionStopped
        ) {
            _ = try await tombstoneFixture.coordinator.prepare(
                inference: makeV2AttemptInference(
                    identity: v2AttemptIdentity(
                        attempt: 25, request: 24, lease: 27)),
                expiresAt: Date().addingTimeInterval(60),
                using: tombstoneExecutor
            )
        }
    }

    @Test("terminal signing failure closes paid admission")
    func terminalSigningFailureClosesAdmission() async throws {
        let fixture = try makeV2AttemptFixture(
            signer: V2AttemptFailingSigner())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executor = V2AttemptTestExecutor(durableRoot: fixture.directory)

        _ = try await fixture.coordinator.activate(
            providerID: fixture.identity.providerID)
        _ = try await fixture.coordinator.prepare(
            inference: makeV2AttemptInference(identity: fixture.identity),
            expiresAt: Date().addingTimeInterval(60),
            using: executor
        )
        _ = try await fixture.coordinator.start(identity: fixture.identity)
        _ = try await fixture.coordinator.cancel(identity: fixture.identity)
        await #expect(throws: V2AttemptTestSignerError.self) {
            _ = try await fixture.coordinator.persistTerminal(
                identity: fixture.identity,
                draft: ProviderTerminalDraft(
                    outcome: .cancelled,
                    errorClass: .cancelled,
                    completionTokens: 0,
                    responseHash: .sha256(Data()),
                    finalGeneratedTokens: 0,
                    rollingDigest: .zero
                ))
        }
        #expect(
            try await fixture.coordinator.paidAdmissionStatus()
                .paidAdmissionAllowed == false)
        await #expect(
            throws: V2PreparedAttemptCoordinatorError.paidAdmissionStopped
        ) {
            _ = try await fixture.coordinator.prepare(
                inference: makeV2AttemptInference(
                    identity: v2AttemptIdentity(
                        attempt: 35, request: 34, lease: 37)),
                expiresAt: Date().addingTimeInterval(60),
                using: executor
            )
        }
    }
}

private struct V2AttemptFixture {
    let directory: URL
    let identity: AttemptIdentity
    let manager: PreparedLeaseManager
    let coordinator: V2PreparedAttemptCoordinator
}

private func makeV2AttemptFixture(
    capacity: TerminalJournalCapacity = .production,
    signer: any TerminalDigestSigner = V2AttemptTestSigner()
) throws -> V2AttemptFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("v2-attempt-\(UUID().uuidString)", isDirectory: true)
    let keySource = V2AttemptTestKeySource(
        key: SymmetricKey(data: Data(repeating: 0x42, count: 32)))
    let manager = PreparedLeaseManager(
        automaticallyExpire: false,
        terminalWaitTimeout: .seconds(1)
    )
    return V2AttemptFixture(
        directory: directory,
        identity: v2AttemptIdentity(),
        manager: manager,
        coordinator: V2PreparedAttemptCoordinator(
            directory: directory,
            signer: signer,
            manager: manager,
            keySource: keySource,
            capacity: capacity
        )
    )
}

private func v2AttemptIdentity(
    attempt: UInt64 = 5,
    request: UInt64 = 4,
    lease: UInt64 = 7
) -> AttemptIdentity {
    AttemptIdentity(
        providerID: v2AttemptUUID(1),
        providerProcessGeneration: v2AttemptUUID(2),
        sessionEpoch: 3,
        requestID: v2AttemptUUID(request),
        attemptID: v2AttemptUUID(attempt),
        reservationID: v2AttemptUUID(6),
        leaseID: v2AttemptUUID(lease)
    )
}

private func v2AttemptUUID(_ value: UInt64) -> ProtocolV2UUID {
    ProtocolV2UUID(
        String(format: "00000000-0000-0000-0000-%012llx", value))!
}

private func makeV2AttemptInference(
    identity: AttemptIdentity,
    resourceRelease: PreparedInferenceResourceRelease =
        PreparedInferenceResourceRelease()
) throws -> PreparedInference {
    try PreparedInference(
        identity: identity,
        requestDigest: Data(repeating: 0x09, count: 32).base64EncodedString(),
        modelID: "test-model",
        promptTokens: [1, 2],
        request: ChatCompletionRequest(
            model: "test-model",
            messages: [ChatMessage(role: "user", content: "hello")],
            max_tokens: 4
        ),
        facts: PreparedInferenceFacts(
            decryptionComplete: true,
            renderingComplete: true,
            tokenizationComplete: true,
            promptTokens: 2,
            maxOutputTokens: 4
        ),
        resourceRelease: resourceRelease
    )
}

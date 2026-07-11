import CryptoKit
import Foundation

public enum V2PreparedAttemptCoordinatorError: Error, Sendable, Equatable {
    case notInitialized
    case providerIdentityChanged
    case paidAdmissionStopped
    case unknownPreparedAttempt
    case identityConflict
    case terminalAckConflict
    case controlDidNotQuiesce
}

public enum V2PreparedStartOutcome: Sendable {
    case started(prepared: PreparedInference, execution: PreparedInferenceExecution)
    case alreadyStarted
}

/// Serializes the three independent actors that make one paid-attempt state
/// machine. The explicit transition gate remains held across actor `await`s;
/// actor reentrancy therefore cannot interleave tombstone, journal, and lease
/// manager mutations into a TOCTOU start.
public actor V2PreparedAttemptCoordinator {
    private struct PreparedBinding: Sendable {
        let lease: PreparedLease
        let inference: PreparedInference
        let executor: any PreparedInferenceExecutor
    }

    private let manager: PreparedLeaseManager
    private let signer: any TerminalDigestSigner
    private let directory: URL
    private let keySource: any ProviderJournalKeySource
    private let capacity: TerminalJournalCapacity

    private var journal: TerminalJournal?
    private var tombstones: AttemptTombstones?
    private var providerID: ProviderID?
    private var bindings: [LeaseID: PreparedBinding] = [:]

    private var transitionHeld = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        directory: URL,
        signer: any TerminalDigestSigner,
        manager: PreparedLeaseManager = PreparedLeaseManager(),
        keySource: any ProviderJournalKeySource = ProviderJournalKey(),
        capacity: TerminalJournalCapacity = .production
    ) {
        self.directory = directory
        self.signer = signer
        self.manager = manager
        self.keySource = keySource
        self.capacity = capacity
    }

    /// Opens durable state only after an authenticated provider ID exists,
    /// resolves every orphan funded start, and returns every unacknowledged
    /// terminal for historical replay. Paid prepare must not run before this
    /// method succeeds.
    public func activate(providerID: ProviderID) async throws
        -> [V2HistoricalTerminalReplay]
    {
        await acquireTransition()
        defer { releaseTransition() }

        if let current = self.providerID {
            guard current == providerID else {
                throw V2PreparedAttemptCoordinatorError.providerIdentityChanged
            }
        } else {
            // Construct the complete durable composition before publishing any
            // member. If one store fails to open, local ownership (including
            // lifetime file locks) is released and a later activation can retry.
            let openedJournal = try TerminalJournal(
                directory: directory,
                providerID: providerID,
                keySource: keySource,
                capacity: capacity
            )
            let openedTombstones = try AttemptTombstones(
                directory: directory,
                providerID: providerID.description,
                keySource: keySource,
                capacity: capacity
            )
            journal = openedJournal
            tombstones = openedTombstones
            self.providerID = providerID
        }

        guard let journal else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        do {
            for start in await journal.durableStartsForRecovery() {
                _ = try await journal.recoverOrphanedStart(
                    attemptID: start.identity.attemptID,
                    reason: .providerRestart,
                    signer: signer
                )
            }
            return try await historicalReplays(journal: journal)
        } catch {
            await journal.stopPaidAdmissionUntilReopen()
            throw error
        }
    }

    public func paidAdmissionStatus() async throws -> ProviderPaidAdmissionStatus {
        guard let journal, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        return await journal.paidAdmissionStatus(including: tombstones)
    }

    /// Reclaims abort tombstones only after the current session's coordinator
    /// key verifies an explicit replay-fence proof. No age- or clock-based
    /// expiration path exists.
    @discardableResult
    public func expireAbortTombstones(
        using proof: CoordinatorReplayFenceProof,
        verifiedBy verifier: any CoordinatorReplayFenceProofVerifier
    ) async throws -> Int {
        await acquireTransition()
        defer { releaseTransition() }
        guard let providerID, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        guard proof.providerID == providerID.description else {
            throw V2PreparedAttemptCoordinatorError.providerIdentityChanged
        }
        return try await tombstones.expire(
            using: proof,
            verifiedBy: verifier
        )
    }

    /// Bounded maintenance backstop for manager-owned terminal transitions.
    /// PreparedLeaseManager can expire, abort, or complete without another
    /// coordinator command; release the model pin and discard this actor's full
    /// decrypted inference binding as soon as that terminal state is observed.
    @discardableResult
    public func reapTerminalBindings(at instant: Date = Date()) async -> Int {
        await acquireTransition()
        defer { releaseTransition() }

        await manager.expireLeases(at: instant)
        var removed = 0
        for (leaseID, binding) in Array(bindings) {
            let state = await manager.state(of: binding.inference.identity)
            switch state {
            case nil, .aborted, .cancelled, .expired, .completed, .failed:
                await binding.inference.resourceRelease.fire()
                bindings.removeValue(forKey: leaseID)
                removed += 1
            case .preparing, .reserved, .starting, .started, .aborting, .cancelling:
                continue
            }
        }
        return removed
    }

    /// Cheap durable gate for the handler before request decryption, model load,
    /// and tokenization. `prepare` repeats every check under a later transition
    /// because an abort can win while those expensive operations are in flight.
    public func validatePrepareAllowed(
        identity: AttemptIdentity
    ) async throws {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        let admission = await journal.paidAdmissionStatus(including: tombstones)
        guard admission.paidAdmissionAllowed else {
            throw V2PreparedAttemptCoordinatorError.paidAdmissionStopped
        }
        try await tombstones.validateStartAllowed(identity)
        if bindings.values.contains(where: {
            $0.inference.identity.attemptID == identity.attemptID
                && $0.inference.identity != identity
        }) {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
    }

    public func prepare(
        inference: PreparedInference,
        expiresAt: Date,
        using executor: any PreparedInferenceExecutor
    ) async throws -> PreparedLease {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal, let tombstones else {
            await inference.resourceRelease.fire()
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        let admission = await journal.paidAdmissionStatus(including: tombstones)
        guard admission.paidAdmissionAllowed else {
            await inference.resourceRelease.fire()
            throw V2PreparedAttemptCoordinatorError.paidAdmissionStopped
        }
        do {
            // An abort can arrive before prepare as well as between prepare and
            // start. Both reorderings are fenced by the same durable tombstone.
            try await tombstones.validateStartAllowed(inference.identity)
        } catch {
            await inference.resourceRelease.fire()
            throw error
        }
        if bindings.values.contains(where: {
            $0.inference.identity.attemptID == inference.identity.attemptID
                && $0.inference.identity != inference.identity
        }) {
            await inference.resourceRelease.fire()
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }

        let lease = try await manager.prepare(
            inference: inference,
            expiresAt: expiresAt,
            using: executor
        )
        if let existing = bindings[lease.leaseID] {
            guard existing.inference.identity == inference.identity,
                existing.inference.requestDigest == inference.requestDigest,
                existing.inference.modelID == inference.modelID
            else {
                throw V2PreparedAttemptCoordinatorError.identityConflict
            }
        } else {
            bindings[lease.leaseID] = PreparedBinding(
                lease: lease, inference: inference, executor: executor)
        }
        return lease
    }

    /// Fast idempotency check used before decrypting, loading, and pinning a
    /// duplicate prepare. A lease-ID collision with any different full
    /// identity, payload digest, or model is a security conflict.
    public func preparedLease(
        identity: AttemptIdentity,
        requestDigest: String,
        modelID: String
    ) async throws -> PreparedLease? {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        // Consult the durable fence before the manager's short-lived tombstone.
        // Otherwise abort-before-prepare is misclassified as a generic cancelled
        // lease after the same-process manager also records the control.
        try await tombstones.validateStartAllowed(identity)
        guard let binding = bindings[identity.leaseID] else {
            if bindings.values.contains(where: {
                $0.inference.identity.attemptID == identity.attemptID
            }) {
                throw V2PreparedAttemptCoordinatorError.identityConflict
            }
            if try await journal.hasTerminal(for: identity) {
                throw PreparedLeaseError.completed
            }
            if let persisted = await journal.durableStart(
                for: identity.attemptID.description)
            {
                guard persisted.identity == (try TerminalAttemptIdentity(identity)) else {
                    throw V2PreparedAttemptCoordinatorError.identityConflict
                }
                throw PreparedLeaseError.completed
            }
            if let state = await manager.state(of: identity) {
                switch state {
                case .expired:
                    throw PreparedLeaseError.expired
                case .aborted, .aborting:
                    throw PreparedLeaseError.aborted
                case .cancelled, .cancelling:
                    throw PreparedLeaseError.cancelled
                case .completed:
                    throw PreparedLeaseError.completed
                case .failed:
                    throw PreparedLeaseError.failed("prepared inference failed")
                case .preparing, .reserved, .starting, .started:
                    throw V2PreparedAttemptCoordinatorError.identityConflict
                }
            }
            return nil
        }
        guard binding.inference.identity == identity,
            binding.inference.requestDigest == requestDigest,
            binding.inference.modelID == modelID
        else {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
        guard let state = await manager.state(of: identity) else {
            bindings.removeValue(forKey: identity.leaseID)
            return nil
        }
        switch state {
        case .reserved, .starting, .started:
            return binding.lease
        case .expired:
            bindings.removeValue(forKey: identity.leaseID)
            throw PreparedLeaseError.expired
        case .aborted, .aborting:
            bindings.removeValue(forKey: identity.leaseID)
            throw PreparedLeaseError.aborted
        case .cancelled, .cancelling:
            bindings.removeValue(forKey: identity.leaseID)
            throw PreparedLeaseError.cancelled
        case .completed:
            // The already-funded stream consumer may still be freezing its durable
            // terminal after the engine completion signal. Preserve the immutable
            // prepared response for exact duplicate prepare commands in that window.
            return binding.lease
        case .failed:
            bindings.removeValue(forKey: identity.leaseID)
            throw PreparedLeaseError.failed("prepared inference failed")
        case .preparing:
            throw PreparedLeaseError.notReady
        }
    }

    /// Reconciles one exact historical attempt from durable journals first,
    /// then the current prepared binding. Tombstones deliberately answer
    /// `unknown`: they prove the queried Start cannot have begun.
    public func attemptStatus(
        identity: AttemptIdentity
    ) async throws -> V2AttemptStatus {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        if let durable = try await journal.attemptStatus(for: identity) {
            return durable
        }
        if try await tombstones.contains(identity) {
            return try V2AttemptStatus(identity: identity, state: .unknown)
        }
        if let binding = bindings[identity.leaseID] {
            guard binding.inference.identity == identity else {
                throw V2PreparedAttemptCoordinatorError.identityConflict
            }
            switch await manager.state(of: identity) {
            case .reserved:
                return try V2AttemptStatus(identity: identity, state: .prepared)
            case nil, .preparing, .starting, .started, .aborting, .aborted,
                .cancelling, .cancelled, .expired, .completed, .failed:
                return try V2AttemptStatus(identity: identity, state: .unknown)
            }
        }
        if bindings.values.contains(where: {
            $0.inference.identity.attemptID == identity.attemptID
        }) {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
        return try V2AttemptStatus(identity: identity, state: .unknown)
    }

    /// Durability order is load-bearing: abort fence validation, funded-start
    /// fsync, then engine submit. A caller may send start_ack only after this
    /// function returns successfully.
    public func start(identity: AttemptIdentity) async throws -> V2PreparedStartOutcome {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal, let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        guard let binding = bindings[identity.leaseID] else {
            if try await journal.hasTerminal(for: identity) {
                return .alreadyStarted
            }
            if let persisted = await journal.durableStart(
                for: identity.attemptID.description)
            {
                guard persisted.identity == (try TerminalAttemptIdentity(identity)) else {
                    throw V2PreparedAttemptCoordinatorError.identityConflict
                }
                return .alreadyStarted
            }
            throw V2PreparedAttemptCoordinatorError.unknownPreparedAttempt
        }
        guard binding.inference.identity == identity else {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }

        if let persisted = await journal.durableStart(
            for: identity.attemptID.description)
        {
            guard persisted.identity == (try TerminalAttemptIdentity(identity)) else {
                throw V2PreparedAttemptCoordinatorError.identityConflict
            }
            // Once the funded start exists, every exact duplicate start is
            // idempotent even if the in-memory manager has already observed engine
            // completion while the stream consumer is still freezing its terminal.
            return .alreadyStarted
        }
        try await tombstones.validateStartAllowed(identity)
        let start = try FundedStartRecord(
            identity: identity,
            model: binding.inference.modelID,
            promptTokens: UInt64(clamping: binding.inference.facts.promptTokens)
        )
        _ = try await journal.reserveFundedStart(start, checking: tombstones)

        do {
            switch try await manager.start(identity: identity) {
            case .started(let execution):
                return .started(prepared: binding.inference, execution: execution)
            case .alreadyStarted:
                return .alreadyStarted
            }
        } catch {
            // Once start is funded there must always be a durable signed
            // terminal, including an engine-submit failure.
            do {
                _ = try await journal.freezeAndPersistTerminal(
                    attemptID: identity.attemptID.description,
                    draft: ProviderTerminalDraft(
                        outcome: .error,
                        errorClass: .fault,
                        completionTokens: 0,
                        responseHash: .sha256(Data()),
                        finalGeneratedTokens: 0,
                        rollingDigest: .zero
                    ),
                    signer: signer
                )
            } catch {
                await journal.stopPaidAdmissionUntilReopen()
                bindings.removeValue(forKey: identity.leaseID)
                throw error
            }
            bindings.removeValue(forKey: identity.leaseID)
            throw error
        }
    }

    /// The durable tombstone is written before the in-memory lease transition
    /// and before the caller is allowed to ACK.
    public func abort(
        identity: AttemptIdentity,
        reason: String?
    ) async throws -> PreparedLeaseControlResult {
        await acquireTransition()
        defer { releaseTransition() }
        guard let tombstones else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        _ = try await tombstones.recordAbort(
            AttemptAbortTombstone(
                identity: identity,
                reason: reason
            ))
        let result = await manager.abort(identity: identity)
        if result == .identityConflict {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
        if result == .aborted || result == .alreadyAborted || result == .expired {
            bindings.removeValue(forKey: identity.leaseID)
        }
        guard result != .failed else {
            throw V2PreparedAttemptCoordinatorError.controlDidNotQuiesce
        }
        return result
    }

    public func cancel(identity: AttemptIdentity) async throws -> PreparedLeaseControlResult {
        await acquireTransition()
        defer { releaseTransition() }
        guard journal != nil else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        let result = await manager.cancel(identity: identity)
        if result == .identityConflict {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
        guard result != .failed else {
            throw V2PreparedAttemptCoordinatorError.controlDidNotQuiesce
        }
        return result
    }

    /// A funded engine start whose `start_ack` could not reach the wire must
    /// never begin response delivery. Quiesce it and freeze a zero-delivery
    /// terminal under the same transition gate; if quiescence or persistence
    /// fails, the funded start remains durable for recovery.
    public func cancelUndeliveredStart(
        identity: AttemptIdentity
    ) async throws -> FrozenProviderTerminal {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        let result = await manager.cancel(identity: identity)
        if result == .identityConflict {
            throw V2PreparedAttemptCoordinatorError.identityConflict
        }
        guard result != .failed else {
            throw V2PreparedAttemptCoordinatorError.controlDidNotQuiesce
        }
        let frozen: FrozenProviderTerminal
        do {
            frozen = try await journal.freezeAndPersistTerminal(
                attemptID: identity.attemptID.description,
                draft: ProviderTerminalDraft(
                    outcome: .cancelled,
                    errorClass: .cancelled,
                    completionTokens: 0,
                    responseHash: .sha256(Data()),
                    finalGeneratedTokens: 0,
                    rollingDigest: .zero
                ),
                signer: signer
            )
        } catch {
            await journal.stopPaidAdmissionUntilReopen()
            throw error
        }
        bindings.removeValue(forKey: identity.leaseID)
        return frozen
    }

    /// A disconnected session can never receive another valid control. Abort
    /// every unstarted lease behind a durable fence and cancel every started
    /// engine stream so its consumer can freeze a terminal for replay.
    public func endSession(_ session: ProviderSessionIdentity) async {
        await acquireTransition()
        defer { releaseTransition() }
        guard let tombstones else { return }
        let affected = bindings.values
            .map(\.inference.identity)
            .filter { $0.belongs(to: session) }
        for identity in affected {
            let state = await manager.state(of: identity)
            switch state {
            case .started, .starting, .cancelling:
                _ = await manager.cancel(identity: identity)
            default:
                if let tombstone = try? AttemptAbortTombstone(
                    identity: identity, reason: "session_ended")
                {
                    _ = try? await tombstones.recordAbort(tombstone)
                }
                _ = await manager.abort(identity: identity)
                bindings.removeValue(forKey: identity.leaseID)
            }
        }
    }

    /// Freezes, signs, and atomically persists before returning a sendable
    /// terminal. Duplicate calls are idempotent only for identical facts.
    public func persistTerminal(
        identity: AttemptIdentity,
        draft: ProviderTerminalDraft
    ) async throws -> FrozenProviderTerminal {
        await acquireTransition()
        defer { releaseTransition() }
        guard let journal else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        let frozen: FrozenProviderTerminal
        do {
            frozen = try await journal.freezeAndPersistTerminal(
                attemptID: identity.attemptID.description,
                draft: draft,
                signer: signer
            )
        } catch {
            await journal.stopPaidAdmissionUntilReopen()
            throw error
        }
        bindings.removeValue(forKey: identity.leaseID)
        return frozen
    }

    /// Conflict dispositions are never success and can never delete local
    /// evidence. Every other disposition still has to pass exact identity and
    /// digest validation in TerminalJournal.
    public func acknowledge(_ acknowledgement: V2TerminalAck) async throws {
        await acquireTransition()
        defer { releaseTransition() }
        guard acknowledgement.disposition != .conflict else {
            throw V2PreparedAttemptCoordinatorError.terminalAckConflict
        }
        guard let journal else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        try await journal.acknowledgeTerminal(acknowledgement)
    }

    public func pendingHistoricalReplays() async throws -> [V2HistoricalTerminalReplay] {
        guard let journal else {
            throw V2PreparedAttemptCoordinatorError.notInitialized
        }
        return try await historicalReplays(journal: journal)
    }

    public func durableStart(for identity: AttemptIdentity) async -> FundedStartRecord? {
        await journal?.durableStart(for: identity.attemptID.description)
    }

    public func pendingTerminalCount() async -> Int {
        await journal?.status.pendingTerminals ?? 0
    }

    func bindingCountForTesting() -> Int {
        bindings.count
    }

    private func historicalReplays(
        journal: TerminalJournal
    ) async throws -> [V2HistoricalTerminalReplay] {
        let publicKey = Data(base64Encoded: signer.publicKeyBase64)
        return try await journal.pendingTerminalsForReplay().map { frozen in
            try V2HistoricalTerminalReplay(
                terminal: frozen.protocolV2,
                verifySignature: { provider, generation, digest, signature in
                    guard provider == frozen.protocolV2.identity.providerID,
                        generation
                            == frozen.protocolV2.identity.providerProcessGeneration,
                        let publicKey,
                        let key = try? P256.Signing.PublicKey(
                            rawRepresentation: publicKey),
                        let signature = try? P256.Signing.ECDSASignature(
                            derRepresentation: signature)
                    else { return false }
                    return key.isValidSignature(signature, for: digest.bytes)
                }
            )
        }
    }

    private func acquireTransition() async {
        if !transitionHeld {
            transitionHeld = true
            return
        }
        await withCheckedContinuation { transitionWaiters.append($0) }
    }

    private func releaseTransition() {
        if transitionWaiters.isEmpty {
            transitionHeld = false
        } else {
            transitionWaiters.removeFirst().resume()
        }
    }
}

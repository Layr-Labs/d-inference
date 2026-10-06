import Foundation
import MLXVLM

enum MiMoV26PendingLoadError: Error, Equatable, Sendable {
    case duplicateClaim, invalidRequest, foreignRequest, invalidProgress
    case usageNotReflected, revoked, invalidLifecycle, invalidReceipt, arithmeticOverflow
}

/// One real process-ledger owner, never an actor pending-load record. Lock order
/// is this revision lock -> ProcessMemoryLedger -> its coherent usage reader.
/// The reader is initialized before this owner can enter native callbacks.
///
/// C is the still-future load promise plus setup KV. Strict SDK source progress
/// removes only its synchronously evaluated, retained source payload from C;
/// ordinary allocator usage now contains it. M ALWAYS remains zero. This is not
/// physical-byte coverage and does not infer credit from a process-memory delta.
final class MiMoV26PendingLoadReservation: MiMoV26SerialLoadReservation, @unchecked Sendable {
    enum Lifecycle: String, Sendable { case loading, setup, revoked, retired }
    struct Snapshot: Sendable {
        let lifecycle: Lifecycle
        let ownerState: ProcessMemoryLedger.OwnerState?
        let provedSourcePayloadBytes: UInt64
        let setupKVBytes: UInt64
        let lastPolicyEpoch: UInt64?
    }

    let request: MiMoV26SerialLoadRequest
    let setupKVBytes: UInt64
    private let ledger: ProcessMemoryLedger
    private let loadReserveBytes: UInt64
    private let initialCharge: UInt64
    private let sourcePayloadBytes: UInt64
    private let claim: MiMoV26LoadClaim
    private let lock = NSLock()
    private var state: ProcessMemoryLedger.OwnerState?
    private var lifecycle = Lifecycle.loading
    private var sourceBytes: UInt64 = 0
    private var lastProgress: MiMoV26SerialLoadProgress?
    private var lastPolicyEpoch: UInt64?

    /// SDK authorization ceiling, NOT current ledger C. The SDK revalidates this
    /// against the original bound during load. Use snapshot() for future charge.
    var reservedLoadBytes: UInt64 {
        lock.withLock { lifecycle == .loading ? request.requiredLoadBytes : 0 }
    }

    init(ledger: ProcessMemoryLedger, request: MiMoV26SerialLoadRequest,
         loadReserveBytes: UInt64, setupKVBytes: UInt64 = UnifiedMemoryCap.minimumLoadKVBytes) throws {
        guard request.binding.contract == MiMoV26LoadFootprint.contract,
            request.binding.scope == "root-bundle-only", request.binding.tensorBytes > 0,
            request.binding.estimate.tensorCount > 0,
            setupKVBytes >= UnifiedMemoryCap.minimumLoadKVBytes,
            let payload = UInt64(exactly: request.binding.tensorBytes), payload <= request.requiredLoadBytes
        else { throw MiMoV26PendingLoadError.invalidRequest }
        let (charge, overflow) = request.requiredLoadBytes.addingReportingOverflow(setupKVBytes)
        guard !overflow else { throw MiMoV26PendingLoadError.arithmeticOverflow }
        ledger.prepareUsageReader()
        let claim = try MiMoV26LoadClaims.acquire(ledger: ledger, sessionID: request.sessionID)
        let empty = ledger.createOwner()
        MiMoV26LoadClaims.attach(owner: empty.owner, to: claim)
        let accepted: ProcessMemoryLedger.OwnerState
        do {
            func reserve() throws -> ProcessMemoryLedger.OwnerState {
                try ledger.replaceCharge(owner: empty.owner, expectedRevision: empty.revision,
                    expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: charge,
                    additionalSystemReserveBytes: loadReserveBytes)
            }
            do { accepted = try reserve() }
            catch ProcessMemoryLedger.Refusal.stalePolicy { accepted = try reserve() }
        } catch {
            _ = ledger.retire(empty.owner) // Failed admission installed no C.
            MiMoV26LoadClaims.remove(claim)
            throw error
        }
        self.ledger = ledger; self.request = request; self.claim = claim
        self.loadReserveBytes = loadReserveBytes; self.setupKVBytes = setupKVBytes
        self.initialCharge = charge; self.sourcePayloadBytes = payload; self.state = accepted
    }

    func snapshot() -> Snapshot {
        lock.withLock { .init(lifecycle: lifecycle, ownerState: state,
            provedSourcePayloadBytes: sourceBytes, setupKVBytes: setupKVBytes,
            lastPolicyEpoch: lastPolicyEpoch) }
    }

    /// Use after host awaits and immediately before handing this exact permit
    /// to the exact SDK session. The SDK independently compares request identity.
    func recheck(for candidate: MiMoV26SerialLoadRequest) throws {
        try lock.withLock {
            guard candidate == request else { throw MiMoV26PendingLoadError.foreignRequest }
            try requireLoadingOrSetup()
            do { try recheckLocked() }
            catch { revokeLocked(); throw error }
        }
    }

    func validateActive(progress: MiMoV26SerialLoadProgress) throws {
        try lock.withLock {
            guard lifecycle == .loading else { throw MiMoV26PendingLoadError.revoked }
            do {
                try validateProgress(progress)
                try requireReflectedUsage(progress.materializedSourcePayloadBytes)
                // Reductions cannot be blocked by a stricter policy/debt. Store
                // their revision before the mandatory fresh capacity recheck;
                // if that fails, keep this reduced promise charged while revoked.
                try replaceLocked(initialCharge - progress.materializedSourcePayloadBytes)
                sourceBytes = progress.materializedSourcePayloadBytes
                lastProgress = progress
                try recheckLocked()
            } catch { revokeLocked(); throw error }
        }
    }

    /// Call only with the receipt returned by a SUCCESSFUL session.load/factory,
    /// never from progress.complete. The SDK has no public receipt constructor.
    /// Keep the whole returned bundle alive; arbitrary component/dtype mutation
    /// before settlement is outside this source-payload accounting contract.
    @discardableResult
    func settleReturnedReceipt(_ receipt: MiMoV26SerialLoadReceipt) throws -> Bool {
        try lock.withLock {
            guard receipt.sessionID == request.sessionID, receipt.binding == request.binding,
                receipt.sourceTensorCount == request.binding.estimate.tensorCount,
                receipt.parameterCount == receipt.sourceTensorCount,
                receipt.materializedSourcePayloadBytes == sourcePayloadBytes,
                !receipt.externalComponentsLoaded, !receipt.payloadHashesRecomputed,
                receipt.materializationPolicy == "serial-source-then-serial-verified-parameters"
            else { throw MiMoV26PendingLoadError.invalidReceipt }
            if lifecycle == .setup { return false }
            guard lifecycle == .loading, lastProgress?.phase == .complete,
                sourceBytes == sourcePayloadBytes else { throw MiMoV26PendingLoadError.invalidLifecycle }
            do {
                try requireReflectedUsage(sourcePayloadBytes)
                try replaceLocked(setupKVBytes)
                lifecycle = .setup
                try recheckLocked()
                return true
            } catch { revokeLocked(); throw error }
        }
    }

    /// Host engine setup is complete and its real runtime owner/ordinary usage
    /// now accounts for resources. Recheck with the held setup floor before
    /// dropping this temporary allowance. Only successful return permits publish.
    @discardableResult
    func finishSetupAfterAccounting() throws -> Bool {
        try lock.withLock {
            if lifecycle == .retired { return false }
            guard lifecycle == .setup else { throw MiMoV26PendingLoadError.invalidLifecycle }
            do {
                try requireReflectedUsage(sourcePayloadBytes)
                try recheckLocked()
                try retireLocked()
                return true
            } catch { revokeLocked(); throw error }
        }
    }

    /// Safe from a cancellation handler: closes to allocation but retains C.
    /// Await actual synchronous loader/factory unwind and native drain before
    /// calling finishFailureAfterNativeDrain; cancellation alone is no proof.
    func revoke() { lock.withLock { revokeLocked() } }

    @discardableResult
    func finishFailureAfterNativeDrain() throws -> Bool {
        try lock.withLock {
            if lifecycle == .retired { return false }
            guard lifecycle == .revoked else { throw MiMoV26PendingLoadError.invalidLifecycle }
            try retireLocked()
            return true
        }
    }

    private func requireLoadingOrSetup() throws {
        guard lifecycle == .loading || lifecycle == .setup else { throw MiMoV26PendingLoadError.revoked }
    }

    private func requireReflectedUsage(_ payload: UInt64) throws {
        let sample = ledger.snapshot()
        let (_, overflow) = sample.usage.activeBytes.addingReportingOverflow(sample.usage.cacheBytes)
        guard !overflow, sample.usage.activeBytes >= payload else {
            throw MiMoV26PendingLoadError.usageNotReflected
        }
        // Necessary counter sanity only. Attribution comes from the strict
        // SDK's still-retained original source handles, not unrelated usage.
    }

    private func replaceLocked(_ bytes: UInt64) throws {
        guard let current = state, current.materializedBytes == 0 else {
            throw MiMoV26PendingLoadError.invalidLifecycle
        }
        state = try ledger.replaceCharge(owner: current.owner, expectedRevision: current.revision,
            expectedPolicyEpoch: 0, chargedBytes: bytes)
    }

    private func recheckLocked() throws {
        guard let current = state else { throw MiMoV26PendingLoadError.invalidLifecycle }
        func check() throws {
            let epoch = ledger.policySnapshot().epoch
            try ledger.recheckCharge(owner: current.owner, expectedRevision: current.revision,
                expectedPolicyEpoch: epoch, additionalSystemReserveBytes: loadReserveBytes)
            lastPolicyEpoch = epoch
        }
        do { try check() }
        catch ProcessMemoryLedger.Refusal.stalePolicy { try check() }
    }

    private func revokeLocked() {
        guard lifecycle != .retired else { return }
        lifecycle = .revoked
        if let current = state {
            _ = ledger.retire(current.owner)
            state = ledger.state(for: current.owner)
        }
    }

    private func retireLocked() throws {
        guard let current = state, current.materializedBytes == 0 else {
            throw MiMoV26PendingLoadError.invalidLifecycle
        }
        try replaceLocked(0)
        _ = ledger.retire(current.owner)
        state = nil; lifecycle = .retired
        MiMoV26LoadClaims.remove(claim)
    }

    private func validateProgress(_ p: MiMoV26SerialLoadProgress) throws {
        let total = request.binding.estimate.tensorCount
        func rank(_ phase: MiMoV26SerialLoadPhase) -> Int {
            switch phase {
            case .admitted: 0
            case .sourceHandles: 1
            case .sourceMaterialization: 2
            case .parameterMaterialization: 3
            case .complete: 4
            @unknown default: -1
            }
        }
        let phase = rank(p.phase), previous = lastProgress.map { rank($0.phase) }
        guard phase >= 0, p.sourceTensorCount == total,
            (0...total).contains(p.sourceTensorsCompleted), p.materializedSourcePayloadBytes <= sourcePayloadBytes,
            p.materializedSourcePayloadBytes >= sourceBytes,
            (0...total).contains(p.parametersCompleted),
            previous.map({ phase >= $0 && phase <= $0 + 1 }) ?? (phase == 0),
            p.sourceTensorsCompleted >= (lastProgress?.sourceTensorsCompleted ?? 0),
            p.parametersCompleted >= (lastProgress?.parametersCompleted ?? 0),
            (p.sourceTensorsCompleted != 0 || p.materializedSourcePayloadBytes == 0),
            (p.sourceTensorsCompleted != total || p.materializedSourcePayloadBytes == sourcePayloadBytes),
            p.materializedSourcePayloadBytes >= UInt64(p.sourceTensorsCompleted),
            sourcePayloadBytes - p.materializedSourcePayloadBytes >= UInt64(total - p.sourceTensorsCompleted)
        else { throw MiMoV26PendingLoadError.invalidProgress }
        if let previous = lastProgress {
            let sameOrAdvancedBytes = p.sourceTensorsCompleted == previous.sourceTensorsCompleted
                ? p.materializedSourcePayloadBytes == previous.materializedSourcePayloadBytes
                : p.materializedSourcePayloadBytes > previous.materializedSourcePayloadBytes
            guard sameOrAdvancedBytes else { throw MiMoV26PendingLoadError.invalidProgress }
        }
        if phase < 2 {
            guard p.sourceTensorsCompleted == 0, p.materializedSourcePayloadBytes == 0 else {
                throw MiMoV26PendingLoadError.invalidProgress
            }
        }
        if phase < 3 {
            guard p.parameterCount == 0, p.parametersCompleted == 0 else { throw MiMoV26PendingLoadError.invalidProgress }
        } else {
            guard p.sourceTensorsCompleted == total, p.materializedSourcePayloadBytes == sourcePayloadBytes,
                p.parameterCount == total else { throw MiMoV26PendingLoadError.invalidProgress }
        }
        if phase == 4, p.parametersCompleted != total { throw MiMoV26PendingLoadError.invalidProgress }
    }

    // Deliberately no deinit/TTL refund. Losing the wrapper cannot establish
    // native drain or erase a still-live owner; the claim remains fail-closed.
}

private final class MiMoV26LoadClaim {
    let ledgerID: ObjectIdentifier
    let sessionID: UUID
    let token = UUID()
    init(ledger: ProcessMemoryLedger, sessionID: UUID) {
        ledgerID = ObjectIdentifier(ledger); self.sessionID = sessionID
    }
}

/// Correlation only, not another budget. Entries are bounded by active tickets
/// or unreleased ledger owners; no permanent consumed-session tombstones.
private enum MiMoV26LoadClaims {
    private final class Entry {
        weak var ledger: ProcessMemoryLedger?
        weak var claim: MiMoV26LoadClaim?
        let token: UUID
        var owner: ProcessMemoryLedger.Owner?
        init(ledger: ProcessMemoryLedger, claim: MiMoV26LoadClaim) {
            self.ledger = ledger; self.claim = claim; token = claim.token
        }
    }
    private struct Key: Hashable { let ledger: ObjectIdentifier; let session: UUID }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Key: Entry] = [:]

    static func acquire(ledger: ProcessMemoryLedger, sessionID: UUID) throws -> MiMoV26LoadClaim {
        try lock.withLock {
            entries = entries.filter { _, entry in
                guard let ledger = entry.ledger else { return false }
                return entry.claim != nil || entry.owner.flatMap { ledger.state(for: $0) } != nil
            }
            let key = Key(ledger: ObjectIdentifier(ledger), session: sessionID)
            guard entries[key] == nil else { throw MiMoV26PendingLoadError.duplicateClaim }
            let claim = MiMoV26LoadClaim(ledger: ledger, sessionID: sessionID)
            entries[key] = Entry(ledger: ledger, claim: claim)
            return claim
        }
    }
    static func attach(owner: ProcessMemoryLedger.Owner, to claim: MiMoV26LoadClaim) {
        lock.withLock {
            let key = Key(ledger: claim.ledgerID, session: claim.sessionID)
            precondition(entries[key]?.token == claim.token)
            entries[key]?.owner = owner
        }
    }
    static func remove(_ claim: MiMoV26LoadClaim) {
        lock.withLock {
            let key = Key(ledger: claim.ledgerID, session: claim.sessionID)
            guard entries[key]?.token == claim.token else { return }
            entries.removeValue(forKey: key)
        }
    }
}

extension GlobalKVCacheBudget {
    /// This REPLACES generic claimPendingLoad for this session. Do not install
    /// the same owner in actor pendingLoads or update its revision from an actor.
    nonisolated func reserveMiMoV26PendingLoad(
        for request: MiMoV26SerialLoadRequest,
        minimumKVBytes: UInt64 = UnifiedMemoryCap.minimumLoadKVBytes
    ) throws -> MiMoV26PendingLoadReservation {
        try .init(ledger: processLedger, request: request, loadReserveBytes: loadReserveBytes,
                  setupKVBytes: minimumKVBytes)
    }
}

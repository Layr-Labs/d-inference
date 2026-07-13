/// Durable abort tombstones for prepared attempts that must never start.
///
/// There is deliberately no TTL or wall-clock reaper. A delayed `start` can
/// outlive reconnects, sleep, clock changes, and process crashes. Tombstones
/// expire only when a caller supplies one of the explicit coordinator-fence
/// policies below.

import CryptoKit
import Foundation

public struct AttemptAbortTombstone: Equatable, Sendable, Codable {
    public let identity: TerminalAttemptIdentity
    public let reason: String?
    public let createdAtUnixMilliseconds: Int64

    public init(
        identity: TerminalAttemptIdentity,
        reason: String? = nil,
        createdAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        if let reason, reason.utf8.count > 1_024 {
            throw AttemptTombstoneError.invalidReason
        }
        self.identity = identity
        self.reason = reason
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    public init(
        identity: AttemptIdentity,
        reason: String? = nil,
        createdAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        try self.init(
            identity: TerminalAttemptIdentity(identity),
            reason: reason,
            createdAtUnixMilliseconds: createdAtUnixMilliseconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case identity
        case reason
        case createdAtUnixMilliseconds = "created_at_unix_ms"
    }
}

public struct AttemptTombstoneStatus: Equatable, Sendable {
    public let retained: Int
    public let quarantined: Int
    public let limit: Int
    public let requiresReopen: Bool

    public var full: Bool {
        requiresReopen || retained + quarantined >= limit
    }
}

public enum AttemptTombstoneWriteResult: Equatable, Sendable {
    case persisted
    case alreadyPersisted
}

private struct StoredReplayFenceProof: Sendable {
    let recordName: String
    let proof: CoordinatorReplayFenceProof
}

/// Coordinator-originated replay fence. `expire(using:)` first persists this
/// proof in the encrypted proof store; tombstones are never removed based only
/// on an in-memory assertion or wall-clock age.
public struct CoordinatorReplayFenceProof: Equatable, Sendable, Codable {
    public let proofID: String
    public let providerID: String
    public let providerProcessGeneration: String
    public let throughSessionEpoch: UInt64
    public let coordinatorRevision: UInt64
    public let proofDigest: TerminalDigest
    public let coordinatorSignature: Data

    enum CodingKeys: String, CodingKey {
        case proofID = "proof_id"
        case providerID = "provider_id"
        case providerProcessGeneration = "provider_process_generation"
        case throughSessionEpoch = "through_session_epoch"
        case coordinatorRevision = "coordinator_revision"
        case proofDigest = "proof_digest"
        case coordinatorSignature = "coordinator_signature"
    }

    public init(
        proofID: String,
        providerID: String,
        providerProcessGeneration: String,
        throughSessionEpoch: UInt64,
        coordinatorRevision: UInt64,
        proofDigest: TerminalDigest,
        coordinatorSignature: Data
    ) throws {
        guard let canonicalProofID = ProtocolV2UUID(proofID),
            let canonicalProviderID = ProtocolV2UUID(providerID),
            let canonicalGeneration = ProtocolV2UUID(providerProcessGeneration)
        else {
            throw AttemptTombstoneError.invalidReplayFenceProof
        }
        guard !coordinatorSignature.isEmpty, coordinatorSignature.count <= 512 else {
            throw AttemptTombstoneError.invalidReplayFenceProof
        }
        let expectedDigest = try Self.signingDigest(
            proofID: canonicalProofID.description,
            providerID: canonicalProviderID.description,
            providerProcessGeneration: canonicalGeneration.description,
            throughSessionEpoch: throughSessionEpoch,
            coordinatorRevision: coordinatorRevision
        )
        guard proofDigest == expectedDigest else {
            throw AttemptTombstoneError.invalidReplayFenceProof
        }
        self.proofID = canonicalProofID.description
        self.providerID = canonicalProviderID.description
        self.providerProcessGeneration = canonicalGeneration.description
        self.throughSessionEpoch = throughSessionEpoch
        self.coordinatorRevision = coordinatorRevision
        self.proofDigest = proofDigest
        self.coordinatorSignature = coordinatorSignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            proofID: container.decode(String.self, forKey: .proofID),
            providerID: container.decode(String.self, forKey: .providerID),
            providerProcessGeneration: container.decode(
                String.self,
                forKey: .providerProcessGeneration
            ),
            throughSessionEpoch: container.decode(
                UInt64.self,
                forKey: .throughSessionEpoch
            ),
            coordinatorRevision: container.decode(
                UInt64.self,
                forKey: .coordinatorRevision
            ),
            proofDigest: container.decode(
                TerminalDigest.self,
                forKey: .proofDigest
            ),
            coordinatorSignature: container.decode(
                Data.self,
                forKey: .coordinatorSignature
            )
        )
    }

    public static func signingDigest(
        proofID: String,
        providerID: String,
        providerProcessGeneration: String,
        throughSessionEpoch: UInt64,
        coordinatorRevision: UInt64
    ) throws -> TerminalDigest {
        guard let proof = ProtocolV2UUID(proofID),
            let provider = ProtocolV2UUID(providerID),
            let generation = ProtocolV2UUID(providerProcessGeneration)
        else {
            throw AttemptTombstoneError.invalidReplayFenceProof
        }
        let unsigned = UnsignedReplayFenceProof(
            schema: "darkbloom.coordinator-replay-fence-proof.v1",
            proofID: proof.description,
            providerID: provider.description,
            providerProcessGeneration: generation.description,
            throughSessionEpoch: throughSessionEpoch,
            coordinatorRevision: coordinatorRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .sha256(try encoder.encode(unsigned))
    }

    fileprivate func permits(_ tombstone: AttemptAbortTombstone) -> Bool {
        tombstone.identity.providerID == providerID
            && tombstone.identity.providerProcessGeneration == providerProcessGeneration
            && tombstone.identity.sessionEpoch <= throughSessionEpoch
    }
}

private struct UnsignedReplayFenceProof: Codable {
    let schema: String
    let proofID: String
    let providerID: String
    let providerProcessGeneration: String
    let throughSessionEpoch: UInt64
    let coordinatorRevision: UInt64

    enum CodingKeys: String, CodingKey {
        case schema
        case proofID = "proof_id"
        case providerID = "provider_id"
        case providerProcessGeneration = "provider_process_generation"
        case throughSessionEpoch = "through_session_epoch"
        case coordinatorRevision = "coordinator_revision"
    }
}

public protocol CoordinatorReplayFenceProofVerifier: Sendable {
    func verifyCoordinatorReplayFenceProof(
        _ proof: CoordinatorReplayFenceProof
    ) throws -> Bool
}

public enum AttemptTombstoneError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidReason
    case capacityFull(occupied: Int, limit: Int)
    case conflictingAbort(String)
    case delayedStartRejected(String)
    case quarantinedAttempt(String)
    case malformedRecord(String)
    case invalidReplayFenceProof
    case conflictingReplayFenceProof(String)
    case replayFenceProofRegression(String)
    case replayFenceProofCapacityFull(occupied: Int, limit: Int)
    case replayFenceProofVerificationFailed
    case requiresReopen
    case invalidProviderID
    case providerIdentityMismatch

    public var description: String {
        switch self {
        case .invalidReason:
            return "abort tombstone reason exceeds 1024 UTF-8 bytes"
        case .capacityFull(let occupied, let limit):
            return "abort tombstone store full: occupied=\(occupied), limit=\(limit)"
        case .conflictingAbort(let attempt):
            return "attempt \(attempt) has a conflicting abort tombstone"
        case .delayedStartRejected(let attempt):
            return "delayed start rejected by durable abort tombstone for \(attempt)"
        case .quarantinedAttempt(let attempt):
            return "attempt \(attempt) has a quarantined abort tombstone"
        case .malformedRecord(let detail):
            return "malformed abort tombstone: \(detail)"
        case .invalidReplayFenceProof:
            return "coordinator replay-fence proof has invalid identity fields"
        case .conflictingReplayFenceProof(let proofID):
            return "coordinator replay-fence proof \(proofID) conflicts with durable proof"
        case .replayFenceProofRegression(let generation):
            return "coordinator replay-fence proof regresses durable generation \(generation)"
        case .replayFenceProofCapacityFull(let occupied, let limit):
            return "coordinator replay-fence proof store full: occupied=\(occupied), limit=\(limit)"
        case .replayFenceProofVerificationFailed:
            return "coordinator replay-fence proof signature verification failed"
        case .requiresReopen:
            return "abort tombstone durability is uncertain and must be reopened"
        case .invalidProviderID:
            return "abort tombstone provider ID must be a canonicalizable UUID"
        case .providerIdentityMismatch:
            return "abort tombstone state does not belong to the acknowledged provider"
        }
    }
}

public actor AttemptTombstones {
    private let store: DurableEncryptedRecordStore
    private let proofStore: DurableEncryptedRecordStore
    private let capacity: TerminalJournalCapacity
    private let currentProviderID: String
    private var tombstones: [String: AttemptAbortTombstone]
    private var replayFenceProofs: [String: StoredReplayFenceProof]
    private var quarantinedNames: Set<String>
    private var quarantinedCount: Int
    private var requiresReopen = false

    public init(
        directory: URL,
        providerID: String,
        keySource: any ProviderJournalKeySource = ProviderJournalKey(),
        capacity: TerminalJournalCapacity = .production
    ) throws {
        guard let currentProviderID = ProtocolV2UUID(providerID)?.description else {
            throw AttemptTombstoneError.invalidProviderID
        }
        let key = try keySource.loadOrCreateKey()
        let store = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("abort-tombstones", isDirectory: true),
            namespace: "abort",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".abort-tombstones.lock"
        )
        let proofStore = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("replay-fences", isDirectory: true),
            namespace: "replay-fence",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".replay-fences.lock"
        )
        var loaded = try Self.load(from: store)
        let proofs = try Self.loadProofs(
            from: proofStore,
            capacity: capacity
        )
        guard
            loaded.tombstones.values.allSatisfy({
                $0.identity.providerID == currentProviderID
            }),
            proofs.allSatisfy({
                $0.proof.providerID == currentProviderID
            })
        else {
            throw AttemptTombstoneError.providerIdentityMismatch
        }
        try Self.reconcilePersistedReplayFences(
            proofs,
            tombstones: &loaded.tombstones,
            tombstoneStore: store,
            proofStore: proofStore
        )
        self.store = store
        self.proofStore = proofStore
        self.capacity = capacity
        self.currentProviderID = currentProviderID
        self.tombstones = loaded.tombstones
        self.replayFenceProofs = [:]
        self.quarantinedNames = loaded.quarantinedNames
        self.quarantinedCount = loaded.quarantinedCount
    }

    init(
        directory: URL,
        providerID: String,
        key: SymmetricKey,
        capacity: TerminalJournalCapacity = .production,
        faults: any JournalFaultInjecting = NoJournalFaults()
    ) throws {
        guard let currentProviderID = ProtocolV2UUID(providerID)?.description else {
            throw AttemptTombstoneError.invalidProviderID
        }
        let store = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("abort-tombstones", isDirectory: true),
            namespace: "abort",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".abort-tombstones.lock",
            faults: faults
        )
        let proofStore = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("replay-fences", isDirectory: true),
            namespace: "replay-fence",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".replay-fences.lock",
            faults: faults
        )
        var loaded = try Self.load(from: store)
        let proofs = try Self.loadProofs(
            from: proofStore,
            capacity: capacity
        )
        guard
            loaded.tombstones.values.allSatisfy({
                $0.identity.providerID == currentProviderID
            }),
            proofs.allSatisfy({
                $0.proof.providerID == currentProviderID
            })
        else {
            throw AttemptTombstoneError.providerIdentityMismatch
        }
        try Self.reconcilePersistedReplayFences(
            proofs,
            tombstones: &loaded.tombstones,
            tombstoneStore: store,
            proofStore: proofStore
        )
        self.store = store
        self.proofStore = proofStore
        self.capacity = capacity
        self.currentProviderID = currentProviderID
        self.tombstones = loaded.tombstones
        self.replayFenceProofs = [:]
        self.quarantinedNames = loaded.quarantinedNames
        self.quarantinedCount = loaded.quarantinedCount
    }

    public var status: AttemptTombstoneStatus {
        AttemptTombstoneStatus(
            retained: tombstones.count,
            quarantined: quarantinedCount,
            limit: capacity.slotLimit,
            requiresReopen: requiresReopen
        )
    }

    public var paidAdmissionAllowed: Bool {
        !status.full
    }

    @discardableResult
    public func recordAbort(
        _ tombstone: AttemptAbortTombstone
    ) throws -> AttemptTombstoneWriteResult {
        guard !requiresReopen else { throw AttemptTombstoneError.requiresReopen }
        guard tombstone.identity.providerID == currentProviderID else {
            throw AttemptTombstoneError.providerIdentityMismatch
        }
        let attemptID = tombstone.identity.attemptID
        let name = Self.recordName(for: attemptID)
        if quarantinedNames.contains(name) {
            throw AttemptTombstoneError.quarantinedAttempt(attemptID)
        }
        if let existing = tombstones[attemptID] {
            // Abort reason is diagnostic, not identity. The first durable
            // reason wins and retries remain idempotent.
            if existing.identity == tombstone.identity {
                return .alreadyPersisted
            }
            throw AttemptTombstoneError.conflictingAbort(attemptID)
        }
        let current = status
        guard !current.full else {
            throw AttemptTombstoneError.capacityFull(
                occupied: current.retained + current.quarantined,
                limit: current.limit
            )
        }

        let plaintext = try Self.encode(AttemptTombstoneEnvelope(tombstone: tombstone))
        do {
            try store.write(name: name, plaintext: plaintext)
        } catch {
            if store.recordExists(name: name) {
                requiresReopen = true
            }
            throw error
        }
        tombstones[attemptID] = tombstone
        return .persisted
    }

    /// Throws for both an exact delayed retry and an attempt-ID collision with
    /// different fence fields. Neither may start.
    public func validateStartAllowed(_ identity: TerminalAttemptIdentity) throws {
        let name = Self.recordName(for: identity.attemptID)
        if quarantinedNames.contains(name) {
            throw AttemptTombstoneError.quarantinedAttempt(identity.attemptID)
        }
        if tombstones[identity.attemptID] != nil {
            throw AttemptTombstoneError.delayedStartRejected(identity.attemptID)
        }
    }

    public func validateStartAllowed(_ identity: AttemptIdentity) throws {
        try validateStartAllowed(TerminalAttemptIdentity(identity))
    }

    public func contains(attemptID: String) -> Bool {
        tombstones[attemptID] != nil
    }

    /// Returns whether the exact historical identity has a durable abort
    /// tombstone. An attempt-ID collision remains a security conflict.
    public func contains(_ identity: AttemptIdentity) throws -> Bool {
        let historical = try TerminalAttemptIdentity(identity)
        guard let tombstone = tombstones[historical.attemptID] else {
            return false
        }
        guard tombstone.identity == historical else {
            throw AttemptTombstoneError.conflictingAbort(historical.attemptID)
        }
        return true
    }

    /// Durably expires only records covered by the explicit replay-fence
    /// policy. Each unlink is directory-fsynced before it is removed from
    /// memory; a partial failure leaves the remaining records retained.
    @discardableResult
    public func expire(
        using proof: CoordinatorReplayFenceProof,
        verifiedBy verifier: any CoordinatorReplayFenceProofVerifier
    ) throws -> Int {
        guard !requiresReopen else { throw AttemptTombstoneError.requiresReopen }
        _ = try persistReplayFenceProof(proof, verifiedBy: verifier)
        let eligible = tombstones.values
            .filter { proof.permits($0) }
            .sorted { $0.identity.attemptID < $1.identity.attemptID }
        var removed = 0
        for tombstone in eligible {
            let attemptID = tombstone.identity.attemptID
            do {
                try store.delete(name: Self.recordName(for: attemptID))
            } catch {
                requiresReopen = true
                throw error
            }
            tombstones.removeValue(forKey: attemptID)
            removed += 1
        }
        try deleteReplayFenceProofIfExhausted(
            forGeneration: proof.providerProcessGeneration
        )
        return removed
    }

    public func durableReplayFenceProofs() -> [CoordinatorReplayFenceProof] {
        replayFenceProofs.values
            .map(\.proof)
            .sorted { $0.proofID < $1.proofID }
    }

    @discardableResult
    public func persistReplayFenceProof(
        _ proof: CoordinatorReplayFenceProof,
        verifiedBy verifier: any CoordinatorReplayFenceProofVerifier
    ) throws -> Bool {
        guard !requiresReopen else { throw AttemptTombstoneError.requiresReopen }
        guard try verifier.verifyCoordinatorReplayFenceProof(proof) else {
            throw AttemptTombstoneError.replayFenceProofVerificationFailed
        }
        guard proof.providerID == currentProviderID else {
            throw AttemptTombstoneError.providerIdentityMismatch
        }

        // A proof is crash-recovery state for the deletions it authorizes, not an
        // audit log. Never allocate disk for unrelated/no-op signed messages.
        guard tombstones.values.contains(where: { proof.permits($0) }) else {
            return false
        }

        let generation = proof.providerProcessGeneration
        if let sameID = replayFenceProofs.values.first(where: {
            $0.proof.proofID == proof.proofID
        })?.proof {
            guard sameID == proof else {
                throw AttemptTombstoneError.conflictingReplayFenceProof(
                    proof.proofID
                )
            }
            return false
        }
        if let existing = replayFenceProofs[generation]?.proof {
            guard
                proof.coordinatorRevision > existing.coordinatorRevision,
                proof.throughSessionEpoch >= existing.throughSessionEpoch
            else {
                throw AttemptTombstoneError.replayFenceProofRegression(generation)
            }
        } else {
            let limit = capacity.slotLimit
            guard replayFenceProofs.count < limit else {
                throw AttemptTombstoneError.replayFenceProofCapacityFull(
                    occupied: replayFenceProofs.count,
                    limit: limit
                )
            }
        }

        let envelope = ReplayFenceProofEnvelope(proof: proof)
        let plaintext = try Self.encode(envelope)
        let name = Self.proofRecordName(
            providerID: proof.providerID,
            generation: generation
        )
        do {
            try proofStore.write(name: name, plaintext: plaintext)
        } catch {
            if proofStore.recordExists(name: name) {
                requiresReopen = true
            }
            throw error
        }
        replayFenceProofs[generation] = StoredReplayFenceProof(
            recordName: name,
            proof: proof
        )
        return true
    }

    private func deleteReplayFenceProofIfExhausted(
        forGeneration generation: String,
    ) throws {
        guard let stored = replayFenceProofs[generation],
            !tombstones.values.contains(where: { stored.proof.permits($0) })
        else { return }
        do {
            try proofStore.delete(name: stored.recordName)
        } catch {
            requiresReopen = true
            throw error
        }
        replayFenceProofs.removeValue(forKey: generation)
    }

    private static func recordName(for attemptID: String) -> String {
        SHA256.hash(data: Data(attemptID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func proofRecordName(
        providerID: String,
        generation: String
    ) -> String {
        recordName(for: "replay-fence:\(providerID):\(generation)")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw AttemptTombstoneError.malformedRecord("encode: \(error)")
        }
    }

    private static func load(
        from store: DurableEncryptedRecordStore
    ) throws -> (
        tombstones: [String: AttemptAbortTombstone],
        quarantinedNames: Set<String>,
        quarantinedCount: Int
    ) {
        let scan = try store.scan()
        guard scan.reservationNames.isEmpty else {
            throw AttemptTombstoneError.malformedRecord(
                "abort tombstone store contains terminal reservations")
        }
        let decoder = JSONDecoder()
        var loaded: [String: AttemptAbortTombstone] = [:]
        var quarantined = scan.quarantinedNames
        var quarantinedCount = scan.quarantinedCount
        for record in scan.records {
            do {
                let envelope = try decoder.decode(
                    AttemptTombstoneEnvelope.self,
                    from: record.plaintext
                )
                let validated = try AttemptAbortTombstone(
                    identity: envelope.tombstone.identity,
                    reason: envelope.tombstone.reason,
                    createdAtUnixMilliseconds: envelope.tombstone.createdAtUnixMilliseconds
                )
                let expectedName = recordName(for: validated.identity.attemptID)
                guard record.name == expectedName,
                    loaded[validated.identity.attemptID] == nil
                else {
                    throw AttemptTombstoneError.malformedRecord(
                        "filename binding or duplicate attempt failed")
                }
                loaded[validated.identity.attemptID] = validated
            } catch {
                try store.quarantineAuthenticatedRecord(
                    name: record.name,
                    reason: String(describing: error)
                )
                quarantined.insert(record.name)
                quarantinedCount += 1
            }
        }
        return (loaded, quarantined, quarantinedCount)
    }

    private static func loadProofs(
        from store: DurableEncryptedRecordStore,
        capacity: TerminalJournalCapacity
    ) throws -> [StoredReplayFenceProof] {
        let scan = try store.scan()
        guard scan.quarantinedCount == 0,
            scan.reservationNames.isEmpty,
            scan.invalidReservationNames.isEmpty
        else {
            throw AttemptTombstoneError.malformedRecord(
                "replay-fence proof store contains quarantine/reservations")
        }
        // Every encrypted proof is individually bounded by the store's
        // maxEncryptedRecordBytes. Limiting count to slotLimit therefore also
        // bounds worst-case proof bytes by maxTotalReservedBytes.
        guard scan.records.count <= capacity.slotLimit else {
            throw AttemptTombstoneError.replayFenceProofCapacityFull(
                occupied: scan.records.count,
                limit: capacity.slotLimit
            )
        }
        let decoder = JSONDecoder()
        var proofs: [StoredReplayFenceProof] = []
        var proofIDs = Set<String>()
        for record in scan.records {
            let envelope = try decoder.decode(
                ReplayFenceProofEnvelope.self, from: record.plaintext)
            let raw = envelope.proof
            let validated = try CoordinatorReplayFenceProof(
                proofID: raw.proofID,
                providerID: raw.providerID,
                providerProcessGeneration: raw.providerProcessGeneration,
                throughSessionEpoch: raw.throughSessionEpoch,
                coordinatorRevision: raw.coordinatorRevision,
                proofDigest: raw.proofDigest,
                coordinatorSignature: raw.coordinatorSignature
            )
            let currentName = proofRecordName(
                providerID: validated.providerID,
                generation: validated.providerProcessGeneration
            )
            let legacyName = recordName(for: validated.proofID)
            guard record.name == currentName || record.name == legacyName,
                proofIDs.insert(validated.proofID).inserted
            else {
                throw AttemptTombstoneError.malformedRecord(
                    "replay-fence proof filename binding failed")
            }
            proofs.append(
                StoredReplayFenceProof(
                    recordName: record.name,
                    proof: validated
                ))
        }
        return proofs
    }

    /// A locally authenticated proof record exists only after signature
    /// verification completed and the proof was file+directory fsynced. On
    /// reopen, finish any interrupted tombstone deletions before removing the
    /// proof itself. This leaves no steady-state proof log.
    private static func reconcilePersistedReplayFences(
        _ proofs: [StoredReplayFenceProof],
        tombstones: inout [String: AttemptAbortTombstone],
        tombstoneStore: DurableEncryptedRecordStore,
        proofStore: DurableEncryptedRecordStore
    ) throws {
        for stored in proofs.sorted(by: {
            if $0.proof.coordinatorRevision == $1.proof.coordinatorRevision {
                return $0.proof.proofID < $1.proof.proofID
            }
            return $0.proof.coordinatorRevision < $1.proof.coordinatorRevision
        }) {
            let eligible = tombstones.values
                .filter { stored.proof.permits($0) }
                .sorted { $0.identity.attemptID < $1.identity.attemptID }
            for tombstone in eligible {
                try tombstoneStore.delete(
                    name: recordName(for: tombstone.identity.attemptID)
                )
                tombstones.removeValue(forKey: tombstone.identity.attemptID)
            }
            try proofStore.delete(name: stored.recordName)
        }
    }
}

private struct AttemptTombstoneEnvelope: Codable {
    let schema: String
    let tombstone: AttemptAbortTombstone

    init(tombstone: AttemptAbortTombstone) {
        self.schema = "darkbloom.abort-tombstone.v1"
        self.tombstone = tombstone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "darkbloom.abort-tombstone.v1" else {
            throw AttemptTombstoneError.malformedRecord("unsupported schema \(schema)")
        }
        tombstone = try container.decode(AttemptAbortTombstone.self, forKey: .tombstone)
    }
}

private struct ReplayFenceProofEnvelope: Codable {
    let schema: String
    let proof: CoordinatorReplayFenceProof

    init(proof: CoordinatorReplayFenceProof) {
        self.schema = "darkbloom.coordinator-replay-fence.v1"
        self.proof = proof
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "darkbloom.coordinator-replay-fence.v1" else {
            throw AttemptTombstoneError.malformedRecord(
                "unsupported replay-fence proof schema \(schema)")
        }
        proof = try container.decode(CoordinatorReplayFenceProof.self, forKey: .proof)
    }
}

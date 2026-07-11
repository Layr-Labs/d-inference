/// Crash-durable encrypted journal for funded starts and signed terminals.
///
/// Safety order:
///
/// 1. reserve bounded capacity;
/// 2. encrypt and durably persist a funded-start record;
/// 3. only then may generation start;
/// 4. freeze and Secure-Enclave-sign terminal facts;
/// 5. encrypt and durably replace the start with the terminal;
/// 6. only then may the terminal be sent;
/// 7. replay after reconnect/restart until an identity- and digest-matching ACK;
/// 8. unlink and fsync the directory before reporting ACK completion.
///
/// Journal plaintext contains identifiers, model name, token counts, hashes,
/// and signatures only. Prompt and completion bytes are never accepted by this
/// API and therefore cannot be persisted.

import CryptoKit
import Foundation

// MARK: - Public records

public struct FundedStartRecord: Equatable, Sendable, Codable {
    public let identity: TerminalAttemptIdentity
    public let model: String
    public let promptTokens: UInt64
    public let fundedAtUnixMilliseconds: Int64

    public init(
        identity: TerminalAttemptIdentity,
        model: String,
        promptTokens: UInt64,
        fundedAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        // Constructing a harmless terminal is the single validation source for
        // the canonical model constraints.
        _ = try CanonicalProviderTerminal(
            identity: identity,
            outcome: .cancelled,
            promptTokens: promptTokens,
            completionTokens: 0,
            responseHash: .sha256(Data()),
            finalGeneratedTokens: 0,
            rollingDigest: .zero,
            model: model
        )
        self.identity = identity
        self.model = model
        self.promptTokens = promptTokens
        self.fundedAtUnixMilliseconds = fundedAtUnixMilliseconds
    }

    public init(
        identity: AttemptIdentity,
        model: String,
        promptTokens: UInt64,
        fundedAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        try self.init(
            identity: TerminalAttemptIdentity(identity),
            model: model,
            promptTokens: promptTokens,
            fundedAtUnixMilliseconds: fundedAtUnixMilliseconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case identity
        case model
        case promptTokens = "prompt_tokens"
        case fundedAtUnixMilliseconds = "funded_at_unix_ms"
    }
}

public struct TerminalJournalCapacity: Equatable, Sendable {
    /// Covers the largest valid encrypted record: 4 KiB model identifier,
    /// fixed identity/digest fields, bounded P-256 DER signature, JSON
    /// escaping, AES-GCM header, and tag. This lower bound is load-bearing:
    /// every admitted start must have enough reserved space for its terminal.
    public static let minimumEncryptedRecordBytes = 16 * 1_024

    public static let production = try! TerminalJournalCapacity(
        maxEntries: 4_096,
        maxEncryptedRecordBytes: 64 * 1_024,
        maxTotalReservedBytes: 256 * 1_024 * 1_024
    )

    public let maxEntries: Int
    public let maxEncryptedRecordBytes: Int
    public let maxTotalReservedBytes: Int

    public init(
        maxEntries: Int,
        maxEncryptedRecordBytes: Int,
        maxTotalReservedBytes: Int
    ) throws {
        guard maxEntries > 0,
            maxEncryptedRecordBytes >= Self.minimumEncryptedRecordBytes,
            maxTotalReservedBytes >= maxEncryptedRecordBytes
        else {
            throw TerminalJournalError.invalidCapacity
        }
        self.maxEntries = maxEntries
        self.maxEncryptedRecordBytes = maxEncryptedRecordBytes
        self.maxTotalReservedBytes = maxTotalReservedBytes
    }

    public var slotLimit: Int {
        min(maxEntries, maxTotalReservedBytes / maxEncryptedRecordBytes)
    }
}

public struct TerminalJournalStatus: Equatable, Sendable {
    public let durableStarts: Int
    public let pendingTerminals: Int
    public let quarantinedRecords: Int
    public let slotLimit: Int
    public let requiresReopen: Bool

    public var occupiedSlots: Int {
        durableStarts + pendingTerminals + quarantinedRecords
    }

    public var paidAdmissionAllowed: Bool {
        !requiresReopen && occupiedSlots < slotLimit
    }
}

public struct ProviderPaidAdmissionStatus: Equatable, Sendable {
    public let terminalJournal: TerminalJournalStatus
    public let tombstones: AttemptTombstoneStatus

    public var paidAdmissionAllowed: Bool {
        terminalJournal.paidAdmissionAllowed && !tombstones.full
    }
}

public enum FundedStartReservation: Equatable, Sendable {
    case persisted
    case alreadyPersisted
}

public enum OrphanedStartRecoveryReason: String, Sendable, Codable {
    case providerRestart = "provider_restart"
    case uncertainStart = "uncertain_start"
    case operatorRecovery = "operator_recovery"
}

public enum TerminalJournalError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidCapacity
    case capacityFull(occupied: Int, limit: Int)
    case recordTooLarge(actual: Int, maximum: Int)
    case unknownAttempt(String)
    case attemptAlreadyTerminal(String)
    case conflictingStart(String)
    case conflictingTerminal(String)
    case terminalWithoutDurableStart(String)
    case ackBeforeTerminal(String)
    case ackIdentityMismatch
    case ackDigestMismatch
    case quarantinedAttempt(String)
    case malformedRecord(String)
    case authenticationFailed
    case ioFailure(String)
    case lockUnavailable(String)
    case systemCall(operation: String, errorNumber: Int32)
    case requiresReopen
    case tombstoneCapacityFull(occupied: Int, limit: Int)
    case invalidProviderID
    case providerIdentityMismatch

    public var description: String {
        switch self {
        case .invalidCapacity:
            return "terminal journal capacity must be positive and internally consistent"
        case .capacityFull(let occupied, let limit):
            return "terminal journal full: occupied=\(occupied), limit=\(limit)"
        case .recordTooLarge(let actual, let maximum):
            return "encrypted journal record is too large: \(actual) > \(maximum)"
        case .unknownAttempt(let attempt):
            return "terminal journal has no attempt \(attempt)"
        case .attemptAlreadyTerminal(let attempt):
            return "attempt \(attempt) already has a durable terminal"
        case .conflictingStart(let attempt):
            return "attempt \(attempt) has a conflicting durable start"
        case .conflictingTerminal(let attempt):
            return "attempt \(attempt) has a conflicting durable terminal"
        case .terminalWithoutDurableStart(let attempt):
            return "attempt \(attempt) cannot freeze a terminal without a durable start"
        case .ackBeforeTerminal(let attempt):
            return "attempt \(attempt) cannot ACK a start record"
        case .ackIdentityMismatch:
            return "terminal ACK identity does not match the pending terminal"
        case .ackDigestMismatch:
            return "terminal ACK digest does not match the pending terminal"
        case .quarantinedAttempt(let attempt):
            return "attempt \(attempt) has a quarantined journal record"
        case .malformedRecord(let detail):
            return "malformed terminal journal record: \(detail)"
        case .authenticationFailed:
            return "terminal journal record authentication failed"
        case .ioFailure(let detail):
            return "terminal journal I/O failure: \(detail)"
        case .lockUnavailable(let path):
            return "terminal journal is already owned by another process or actor: \(path)"
        case .systemCall(let operation, let errorNumber):
            return "terminal journal \(operation) failed: errno \(errorNumber)"
        case .requiresReopen:
            return "terminal journal durability is uncertain and must be reopened"
        case .tombstoneCapacityFull(let occupied, let limit):
            return "abort tombstone capacity full (\(occupied)/\(limit)); paid admission stopped"
        case .invalidProviderID:
            return "journal provider ID must be a canonicalizable UUID"
        case .providerIdentityMismatch:
            return "funded start provider ID does not match the current connection identity"
        }
    }
}

// MARK: - Journal actor

public actor TerminalJournal {
    private enum Entry: Equatable {
        case start(FundedStartRecord)
        case terminal(FrozenProviderTerminal)

        var attemptID: String {
            switch self {
            case .start(let start): start.identity.attemptID
            case .terminal(let terminal): terminal.terminal.identity.attemptID
            }
        }
    }

    private let store: DurableEncryptedRecordStore
    private let capacity: TerminalJournalCapacity
    private let currentProviderID: String
    private var entries: [String: Entry]
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
            throw TerminalJournalError.invalidProviderID
        }
        let key = try keySource.loadOrCreateKey()
        let store = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("terminals", isDirectory: true),
            namespace: "terminal",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".terminal-journal.lock"
        )
        let loaded = try Self.loadEntries(
            from: store,
            expectedProviderID: currentProviderID
        )
        self.store = store
        self.capacity = capacity
        self.currentProviderID = currentProviderID
        self.entries = loaded.entries
        self.quarantinedNames = loaded.quarantinedNames
        self.quarantinedCount = loaded.quarantinedCount
    }

    public init(
        directory: URL,
        providerID: ProviderID,
        keySource: any ProviderJournalKeySource = ProviderJournalKey(),
        capacity: TerminalJournalCapacity = .production
    ) throws {
        let key = try keySource.loadOrCreateKey()
        let store = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("terminals", isDirectory: true),
            namespace: "terminal",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".terminal-journal.lock"
        )
        let loaded = try Self.loadEntries(
            from: store,
            expectedProviderID: providerID.description
        )
        self.store = store
        self.capacity = capacity
        self.currentProviderID = providerID.description
        self.entries = loaded.entries
        self.quarantinedNames = loaded.quarantinedNames
        self.quarantinedCount = loaded.quarantinedCount
    }

    /// Key-material injection is internal and exists only at the real key
    /// boundary. `@testable` tests still exercise production AES-GCM and POSIX
    /// durability against a real temporary filesystem.
    init(
        directory: URL,
        providerID: String,
        key: SymmetricKey,
        capacity: TerminalJournalCapacity = .production,
        faults: any JournalFaultInjecting = NoJournalFaults()
    ) throws {
        guard let currentProviderID = ProtocolV2UUID(providerID)?.description else {
            throw TerminalJournalError.invalidProviderID
        }
        let store = try DurableEncryptedRecordStore(
            directory: directory.appendingPathComponent("terminals", isDirectory: true),
            namespace: "terminal",
            key: key,
            maximumRecordBytes: capacity.maxEncryptedRecordBytes,
            lockName: ".terminal-journal.lock",
            faults: faults
        )
        let loaded = try Self.loadEntries(
            from: store,
            expectedProviderID: currentProviderID
        )
        self.store = store
        self.capacity = capacity
        self.currentProviderID = currentProviderID
        self.entries = loaded.entries
        self.quarantinedNames = loaded.quarantinedNames
        self.quarantinedCount = loaded.quarantinedCount
    }

    public var status: TerminalJournalStatus {
        var starts = 0
        var terminals = 0
        for entry in entries.values {
            switch entry {
            case .start: starts += 1
            case .terminal: terminals += 1
            }
        }
        return TerminalJournalStatus(
            durableStarts: starts,
            pendingTerminals: terminals,
            quarantinedRecords: quarantinedCount,
            slotLimit: capacity.slotLimit,
            requiresReopen: requiresReopen
        )
    }

    public var paidAdmissionAllowed: Bool {
        status.paidAdmissionAllowed
    }

    /// Fail closed when a funded obligation cannot be converted into a signed
    /// durable terminal. The current in-memory snapshot must not admit more paid
    /// starts; reopening the journal (normally on process restart) is required.
    func stopPaidAdmissionUntilReopen() {
        requiresReopen = true
    }

    public func paidAdmissionStatus(
        including tombstones: AttemptTombstones
    ) async -> ProviderPaidAdmissionStatus {
        let tombstoneStatus = await tombstones.status
        return ProviderPaidAdmissionStatus(
            terminalJournal: status,
            tombstones: tombstoneStatus
        )
    }

    /// Paid admission entry point when abort fencing is active. The durable
    /// tombstone store participates in the decision instead of being treated
    /// as unrelated diagnostic storage.
    public func reserveFundedStart(
        _ start: FundedStartRecord,
        checking tombstones: AttemptTombstones
    ) async throws -> FundedStartReservation {
        let tombstoneStatus = await tombstones.status
        guard !tombstoneStatus.full else {
            throw TerminalJournalError.tombstoneCapacityFull(
                occupied: tombstoneStatus.retained + tombstoneStatus.quarantined,
                limit: tombstoneStatus.limit
            )
        }
        try await tombstones.validateStartAllowed(start.identity)
        return try reserveFundedStart(start)
    }

    /// Reserve one terminal slot and durably persist start authorization.
    /// A caller must not start funded inference until this method returns.
    @discardableResult
    public func reserveFundedStart(
        _ start: FundedStartRecord
    ) throws -> FundedStartReservation {
        guard !requiresReopen else { throw TerminalJournalError.requiresReopen }
        guard start.identity.providerID == currentProviderID else {
            throw TerminalJournalError.providerIdentityMismatch
        }
        let attemptID = start.identity.attemptID
        let recordName = Self.recordName(for: attemptID)
        if quarantinedNames.contains(recordName) {
            throw TerminalJournalError.quarantinedAttempt(attemptID)
        }
        if let existing = entries[attemptID] {
            switch existing {
            case .start(let persisted)
            where persisted.identity == start.identity
                && persisted.model == start.model
                && persisted.promptTokens == start.promptTokens:
                // The local persistence timestamp is diagnostic and is not
                // present on a wire `start`; retries reconstructed later must
                // remain idempotent even though their local clock differs.
                return .alreadyPersisted
            case .start:
                throw TerminalJournalError.conflictingStart(attemptID)
            case .terminal:
                throw TerminalJournalError.attemptAlreadyTerminal(attemptID)
            }
        }
        let current = status
        guard current.paidAdmissionAllowed else {
            throw TerminalJournalError.capacityFull(
                occupied: current.occupiedSlots,
                limit: current.slotLimit
            )
        }

        let envelope = TerminalJournalEnvelope(start: start)
        let plaintext = try Self.encode(envelope)
        do {
            try store.reserveTerminalSpace(name: recordName)
        } catch {
            do {
                try store.consumeTerminalReservation(name: recordName)
            } catch {
                requiresReopen = true
            }
            throw error
        }
        do {
            try store.write(name: recordName, plaintext: plaintext)
        } catch {
            if store.recordExists(name: recordName) {
                // Rename may have succeeded while directory fsync failed.
                // This actor's snapshot can no longer decide durability.
                requiresReopen = true
            } else {
                do {
                    try store.consumeTerminalReservation(name: recordName)
                } catch {
                    requiresReopen = true
                }
            }
            throw error
        }
        entries[attemptID] = .start(start)
        return .persisted
    }

    /// Freeze/sign terminal facts and atomically replace the durable start.
    /// The returned value is safe to send: its encrypted terminal record has
    /// already reached file fsync, atomic rename, and directory fsync.
    public func freezeAndPersistTerminal(
        attemptID: String,
        draft: ProviderTerminalDraft,
        signer: any TerminalDigestSigner,
        reviewRequired: Bool = false,
        recoveryReason: OrphanedStartRecoveryReason? = nil
    ) throws -> FrozenProviderTerminal {
        guard !requiresReopen else { throw TerminalJournalError.requiresReopen }
        guard let entry = entries[attemptID] else {
            throw TerminalJournalError.terminalWithoutDurableStart(attemptID)
        }

        let identity: TerminalAttemptIdentity
        let model: String
        let promptTokens: UInt64
        switch entry {
        case .start(let start):
            identity = start.identity
            model = start.model
            promptTokens = start.promptTokens
        case .terminal(let frozen):
            let desired = try Self.makeCanonical(
                identity: frozen.terminal.identity,
                model: frozen.terminal.model,
                promptTokens: frozen.terminal.promptTokens,
                draft: draft
            )
            guard desired == frozen.terminal else {
                throw TerminalJournalError.conflictingTerminal(attemptID)
            }
            if store.terminalReservationExists(name: Self.recordName(for: attemptID)) {
                do {
                    try store.consumeTerminalReservation(name: Self.recordName(for: attemptID))
                } catch {
                    requiresReopen = true
                    throw error
                }
            }
            // Idempotent duplicate terminal: never produce a second ECDSA
            // signature or rewrite a record that is already durable.
            return frozen
        }

        let canonical = try Self.makeCanonical(
            identity: identity,
            model: model,
            promptTokens: promptTokens,
            draft: draft
        )
        let digest = canonical.terminalDigest
        let signature = try signer.signTerminalDigest(digest)
        guard signature.count <= 128,
            (try? P256.Signing.ECDSASignature(derRepresentation: signature)) != nil
        else {
            throw TerminalJournalError.malformedRecord(
                "terminal signer returned an invalid P-256 DER signature")
        }
        let frozen = FrozenProviderTerminal(
            terminal: canonical,
            terminalDigest: digest,
            seSignature: signature,
            reviewRequired: reviewRequired,
            recoveryReason: recoveryReason?.rawValue
        )
        let plaintext = try Self.encode(TerminalJournalEnvelope(terminal: frozen))
        do {
            try store.writeConsumingReservation(
                name: Self.recordName(for: attemptID),
                plaintext: plaintext
            )
        } catch {
            // The store keeps either the funded start plus reservation/staged
            // terminal, or a directory-durable terminal. Reopen reconciles which
            // side of that transition survived before any re-sign attempt.
            requiresReopen = true
            throw error
        }
        entries[attemptID] = .terminal(frozen)
        return frozen
    }

    /// Every call returns all unacknowledged terminals in stable attempt order.
    /// There is intentionally no "sent" state: disconnects and crashes replay
    /// until a digest-matching ACK durably deletes the record.
    public func pendingTerminalsForReplay() -> [FrozenProviderTerminal] {
        entries.keys.sorted().compactMap {
            guard case .terminal(let terminal) = entries[$0] else { return nil }
            return terminal
        }
    }

    /// Accept an ACK only for the exact identity and terminal digest. Deletion
    /// is reported successful only after unlink plus directory fsync.
    public func acknowledgeTerminal(
        identity: TerminalAttemptIdentity,
        terminalDigest: TerminalDigest
    ) throws {
        let attemptID = identity.attemptID
        guard let entry = entries[attemptID] else {
            throw TerminalJournalError.unknownAttempt(attemptID)
        }
        guard case .terminal(let terminal) = entry else {
            throw TerminalJournalError.ackBeforeTerminal(attemptID)
        }
        guard terminal.terminal.identity == identity else {
            throw TerminalJournalError.ackIdentityMismatch
        }
        guard terminal.terminalDigest == terminalDigest else {
            throw TerminalJournalError.ackDigestMismatch
        }

        try store.delete(name: Self.recordName(for: attemptID))
        entries.removeValue(forKey: attemptID)
    }

    public func acknowledgeTerminal(_ acknowledgement: V2TerminalAck) throws {
        try acknowledgeTerminal(
            identity: TerminalAttemptIdentity(acknowledgement.identity),
            terminalDigest: TerminalDigest(acknowledgement.terminalDigest)
        )
    }

    public func durableStart(for attemptID: String) -> FundedStartRecord? {
        guard case .start(let start) = entries[attemptID] else { return nil }
        return start
    }

    /// Returns true only when the exact attempt identity already has a durable
    /// terminal. An attempt-ID collision is a conflict, never an idempotent
    /// duplicate.
    public func hasTerminal(for identity: AttemptIdentity) throws -> Bool {
        guard let entry = entries[identity.attemptID.description] else {
            return false
        }
        switch entry {
        case .start:
            return false
        case .terminal(let terminal):
            guard terminal.terminal.identity == (try TerminalAttemptIdentity(identity)) else {
                throw TerminalJournalError.conflictingTerminal(
                    identity.attemptID.description)
            }
            return true
        }
    }

    /// Enumerates funded starts that survived without a terminal. Callers must
    /// resolve each before normal paid admission resumes after process restart.
    public func durableStartsForRecovery() -> [FundedStartRecord] {
        entries.values.compactMap { entry in
            guard case .start(let start) = entry else { return nil }
            return start
        }.sorted { $0.identity.attemptID < $1.identity.attemptID }
    }

    /// Atomically turns an orphan funded start into a signed cancellation that
    /// is explicitly review-required, then enters normal terminal replay.
    public func recoverOrphanedStart(
        attemptID: String,
        reason: OrphanedStartRecoveryReason,
        signer: any TerminalDigestSigner
    ) throws -> FrozenProviderTerminal {
        guard case .start? = entries[attemptID] else {
            if case .terminal(let existing)? = entries[attemptID],
                existing.reviewRequired
            {
                return existing
            }
            throw TerminalJournalError.terminalWithoutDurableStart(attemptID)
        }
        return try freezeAndPersistTerminal(
            attemptID: attemptID,
            draft: ProviderTerminalDraft(
                outcome: .cancelled,
                errorClass: .fault,
                completionTokens: 0,
                responseHash: .sha256(Data()),
                finalGeneratedTokens: 0,
                rollingDigest: .zero
            ),
            signer: signer,
            reviewRequired: true,
            recoveryReason: reason
        )
    }

    private static func makeCanonical(
        identity: TerminalAttemptIdentity,
        model: String,
        promptTokens: UInt64,
        draft: ProviderTerminalDraft
    ) throws -> CanonicalProviderTerminal {
        try CanonicalProviderTerminal(
            identity: identity,
            outcome: draft.outcome,
            errorClass: draft.errorClass,
            promptTokens: promptTokens,
            completionTokens: draft.completionTokens,
            reasoningTokens: draft.reasoningTokens,
            responseHash: draft.responseHash,
            finalGeneratedTokens: draft.finalGeneratedTokens,
            rollingDigest: draft.rollingDigest,
            model: model
        )
    }

    private static func recordName(for attemptID: String) -> String {
        SHA256.hash(data: Data(attemptID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw TerminalJournalError.malformedRecord("encode: \(error)")
        }
    }

    private static func decodeValidatedTerminal(
        from plaintext: Data,
        using decoder: JSONDecoder
    ) throws -> FrozenProviderTerminal {
        let envelope = try decoder.decode(
            TerminalJournalEnvelope.self,
            from: plaintext
        )
        guard envelope.state == .terminal,
            let terminal = envelope.terminal,
            envelope.start == nil
        else {
            throw TerminalJournalError.malformedRecord("invalid terminal envelope")
        }
        let facts = terminal.terminal
        let validated = try CanonicalProviderTerminal(
            identity: facts.identity,
            outcome: facts.outcome,
            errorClass: facts.errorClass,
            promptTokens: facts.promptTokens,
            completionTokens: facts.completionTokens,
            reasoningTokens: facts.reasoningTokens,
            responseHash: facts.responseHash,
            finalGeneratedTokens: facts.finalGeneratedTokens,
            rollingDigest: facts.rollingDigest,
            model: facts.model
        )
        guard validated == facts,
            facts.terminalDigest == terminal.terminalDigest,
            terminal.seSignature.count <= 128,
            (try? P256.Signing.ECDSASignature(
                derRepresentation: terminal.seSignature)) != nil
        else {
            throw TerminalJournalError.malformedRecord(
                "terminal digest/signature validation failed")
        }
        return terminal
    }

    private static func loadEntries(
        from store: DurableEncryptedRecordStore,
        expectedProviderID: String
    ) throws -> (
        entries: [String: Entry],
        quarantinedNames: Set<String>,
        quarantinedCount: Int
    ) {
        let scan = try store.scan()
        var entries: [String: Entry] = [:]
        var quarantined = scan.quarantinedNames
        var quarantinedCount = scan.quarantinedCount
        let decoder = JSONDecoder()

        for record in scan.records {
            do {
                let envelope = try decoder.decode(
                    TerminalJournalEnvelope.self,
                    from: record.plaintext
                )
                let entry: Entry
                switch envelope.state {
                case .fundedStart:
                    guard let start = envelope.start, envelope.terminal == nil else {
                        throw TerminalJournalError.malformedRecord("invalid funded_start envelope")
                    }
                    // Re-run public construction validation after decode.
                    let validated = try FundedStartRecord(
                        identity: start.identity,
                        model: start.model,
                        promptTokens: start.promptTokens,
                        fundedAtUnixMilliseconds: start.fundedAtUnixMilliseconds
                    )
                    entry = .start(validated)
                case .terminal:
                    entry = .terminal(
                        try decodeValidatedTerminal(
                            from: record.plaintext,
                            using: decoder
                        ))
                }

                let expectedName = recordName(for: entry.attemptID)
                guard record.name == expectedName, entries[entry.attemptID] == nil else {
                    throw TerminalJournalError.malformedRecord(
                        "filename binding or duplicate attempt failed")
                }
                entries[entry.attemptID] = entry
            } catch {
                try store.quarantineAuthenticatedRecord(
                    name: record.name,
                    reason: String(describing: error)
                )
                quarantined.insert(record.name)
                quarantinedCount += 1
            }
        }

        // A valid record belonging to another coordinator-assigned provider is
        // not malformed and must never be quarantined or re-signed. Refuse the
        // entire open so paid admission stays closed under identity drift.
        guard
            entries.values.allSatisfy({ entry in
                switch entry {
                case .start(let start):
                    start.identity.providerID == expectedProviderID
                case .terminal(let terminal):
                    terminal.terminal.identity.providerID == expectedProviderID
                }
            })
        else {
            throw TerminalJournalError.providerIdentityMismatch
        }

        // A crash after terminal bytes and their shortened logical length were
        // fsynced can leave the funded-start record beside a valid staged
        // reservation. Authenticate and validate that terminal before completing
        // the inode-preserving rename. A crash after rename may instead leave the
        // terminal record plus its still-linked reservation; that link is then
        // redundant only when both terminals are byte-for-byte identical.
        for (name, stagedRecord) in scan.stagedReservations.sorted(by: {
            $0.key < $1.key
        }) {
            let staged = try decodeValidatedTerminal(
                from: stagedRecord.plaintext,
                using: decoder
            )
            let attemptID = staged.terminal.identity.attemptID
            guard name == recordName(for: attemptID),
                staged.terminal.identity.providerID == expectedProviderID,
                let existing = entries[attemptID]
            else {
                throw TerminalJournalError.malformedRecord(
                    "staged terminal filename/provider binding failed")
            }

            switch existing {
            case .start(let start):
                guard staged.terminal.identity == start.identity,
                    staged.terminal.model == start.model,
                    staged.terminal.promptTokens == start.promptTokens
                else {
                    throw TerminalJournalError.conflictingTerminal(attemptID)
                }
                try store.commitStagedReservation(name: name)
                entries[attemptID] = .terminal(staged)
            case .terminal(let terminal):
                guard staged == terminal else {
                    throw TerminalJournalError.conflictingTerminal(attemptID)
                }
                try store.commitStagedReservation(name: name)
            }
        }

        let starts = Set(
            entries.values.compactMap { entry -> String? in
                guard case .start = entry else { return nil }
                return recordName(for: entry.attemptID)
            })
        for startName in starts
        where !scan.reservationNames.contains(startName)
            || scan.invalidReservationNames.contains(startName)
        {
            throw TerminalJournalError.malformedRecord(
                "funded start \(startName) is missing reserved terminal space")
        }
        if !scan.invalidReservationNames.intersection(quarantined).isEmpty {
            throw TerminalJournalError.malformedRecord(
                "quarantined funded obligation has invalid terminal reservation")
        }
        for reservation in scan.reservationNames
        where !starts.contains(reservation)
            && !quarantined.contains(reservation)
            && scan.stagedReservations[reservation] == nil
        {
            // A durable terminal makes its old reservation redundant. A
            // reservation without any record came from a crash before funded
            // start durability returned and is also safe to release.
            try store.consumeTerminalReservation(name: reservation)
        }
        return (entries, quarantined, quarantinedCount)
    }
}

// MARK: - Encrypted envelope

private struct TerminalJournalEnvelope: Codable {
    enum State: String, Codable {
        case fundedStart = "funded_start"
        case terminal
    }

    let schema: String
    let state: State
    let start: FundedStartRecord?
    let terminal: FrozenProviderTerminal?

    init(start: FundedStartRecord) {
        self.schema = "darkbloom.terminal-journal.v1"
        self.state = .fundedStart
        self.start = start
        self.terminal = nil
    }

    init(terminal: FrozenProviderTerminal) {
        self.schema = "darkbloom.terminal-journal.v1"
        self.state = .terminal
        self.start = nil
        self.terminal = terminal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "darkbloom.terminal-journal.v1" else {
            throw TerminalJournalError.malformedRecord("unsupported schema \(schema)")
        }
        state = try container.decode(State.self, forKey: .state)
        start = try container.decodeIfPresent(FundedStartRecord.self, forKey: .start)
        terminal = try container.decodeIfPresent(FrozenProviderTerminal.self, forKey: .terminal)
    }
}

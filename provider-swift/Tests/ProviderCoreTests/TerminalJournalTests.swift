import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private final class SoftwareTerminalSigner: TerminalDigestSigner, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var _signCallCount = 0

    var signCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _signCallCount
    }

    var publicKeyBase64: String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func signTerminalDigest(_ digest: TerminalDigest) throws -> Data {
        lock.lock()
        _signCallCount += 1
        lock.unlock()
        return try key.signature(for: digest.bytes).derRepresentation
    }

    func verifies(_ frozen: FrozenProviderTerminal) throws -> Bool {
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: frozen.seSignature)
        return key.publicKey.isValidSignature(signature, for: frozen.terminalDigest.bytes)
    }
}

private final class SoftwareReplayFenceAuthority:
    CoordinatorReplayFenceProofVerifier, @unchecked Sendable
{
    private let key = P256.Signing.PrivateKey()

    func sign(_ digest: TerminalDigest) throws -> Data {
        try key.signature(for: digest.bytes).derRepresentation
    }

    func verifyCoordinatorReplayFenceProof(
        _ proof: CoordinatorReplayFenceProof
    ) throws -> Bool {
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: proof.coordinatorSignature)
        return key.publicKey.isValidSignature(signature, for: proof.proofDigest.bytes)
    }
}

private let replayFenceAuthority = SoftwareReplayFenceAuthority()

private struct JournalFixture {
    let root: URL
    let key: SymmetricKey
    let providerID: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "terminal-journal-\(UUID().uuidString)", isDirectory: true)
        key = SymmetricKey(size: .bits256)
        providerID = "11111111-1111-1111-1111-111111111111"
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func journal(
        capacity: TerminalJournalCapacity = .production,
        key override: SymmetricKey? = nil,
        providerID overrideProviderID: String? = nil,
        faults: any JournalFaultInjecting = NoJournalFaults()
    ) throws -> TerminalJournal {
        try TerminalJournal(
            directory: root,
            providerID: overrideProviderID ?? providerID,
            key: override ?? key,
            capacity: capacity,
            faults: faults
        )
    }

    func tombstones(
        capacity: TerminalJournalCapacity = .production,
        faults: any JournalFaultInjecting = NoJournalFaults()
    ) throws -> AttemptTombstones {
        try AttemptTombstones(
            directory: root,
            providerID: providerID,
            key: key,
            capacity: capacity,
            faults: faults
        )
    }

    var terminalRecordsDirectory: URL {
        root.appendingPathComponent("terminals/records", isDirectory: true)
    }

    var terminalQuarantineDirectory: URL {
        root.appendingPathComponent("terminals/quarantine", isDirectory: true)
    }

    var terminalReservationsDirectory: URL {
        root.appendingPathComponent("terminals/reservations", isDirectory: true)
    }

    var tombstoneRecordsDirectory: URL {
        root.appendingPathComponent("abort-tombstones/records", isDirectory: true)
    }
}

private func fixtureUUID(_ value: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012x", value)
}

private func journalIdentity(
    attempt: Int,
    lease: Int? = nil,
    generation: Int = 2,
    epoch: UInt64 = 7
) throws -> TerminalAttemptIdentity {
    try TerminalAttemptIdentity(
        providerID: fixtureUUID(1),
        providerProcessGeneration: fixtureUUID(generation),
        sessionEpoch: epoch,
        requestID: fixtureUUID(10_000 + attempt),
        attemptID: fixtureUUID(attempt),
        reservationID: fixtureUUID(20_000 + attempt),
        leaseID: fixtureUUID(lease ?? 30_000 + attempt)
    )
}

private func fundedStart(
    attempt: Int,
    lease: Int? = nil,
    generation: Int = 2,
    epoch: UInt64 = 7,
    model: String = "org/private-model-marker"
) throws -> FundedStartRecord {
    try FundedStartRecord(
        identity: journalIdentity(
            attempt: attempt, lease: lease, generation: generation, epoch: epoch),
        model: model,
        promptTokens: 41,
        fundedAtUnixMilliseconds: 1_700_000_000_000
    )
}

private func terminalDraft(
    completionTokens: UInt64 = 5,
    outcome: ProviderTerminalOutcome = .completed
) -> ProviderTerminalDraft {
    ProviderTerminalDraft(
        outcome: outcome,
        completionTokens: completionTokens,
        responseHash: .sha256(Data("response-hash-input".utf8)),
        finalGeneratedTokens: completionTokens,
        rollingDigest: .sha256(Data("rolling-hash-input".utf8))
    )
}

private func replayFenceProof(
    id: Int,
    identity: TerminalAttemptIdentity,
    throughEpoch: UInt64
) throws -> CoordinatorReplayFenceProof {
    let proofID = fixtureUUID(id)
    let digest = try CoordinatorReplayFenceProof.signingDigest(
        proofID: proofID,
        providerID: identity.providerID,
        providerProcessGeneration: identity.providerProcessGeneration,
        throughSessionEpoch: throughEpoch,
        coordinatorRevision: UInt64(id)
    )
    return try CoordinatorReplayFenceProof(
        proofID: proofID,
        providerID: identity.providerID,
        providerProcessGeneration: identity.providerProcessGeneration,
        throughSessionEpoch: throughEpoch,
        coordinatorRevision: UInt64(id),
        proofDigest: digest,
        coordinatorSignature: try replayFenceAuthority.sign(digest)
    )
}

private func directoryFiles(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
}

private func hashedRecordName(_ identity: String) -> String {
    SHA256.hash(data: Data(identity.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func inodeNumber(at url: URL) throws -> UInt64 {
    var metadata = stat()
    let result = url.path.withCString { path in
        #if canImport(Darwin)
            Darwin.lstat(path, &metadata)
        #elseif canImport(Glibc)
            Glibc.lstat(path, &metadata)
        #else
            -1
        #endif
    }
    guard result == 0 else {
        throw TerminalJournalError.systemCall(
            operation: "stat test inode",
            errorNumber: errno
        )
    }
    return UInt64(metadata.st_ino)
}

@Test
func fundedStartAndTerminalSurviveCrashReopenWithoutPlaintext() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let start = try fundedStart(attempt: 101)

    do {
        let journal = try fixture.journal()
        #expect(try await journal.reserveFundedStart(start) == .persisted)
    }

    let filesAfterStart = try directoryFiles(fixture.terminalRecordsDirectory)
    let startFile = try #require(filesAfterStart.first)
    let encryptedStart = try Data(contentsOf: startFile)
    #expect(encryptedStart.range(of: Data(start.model.utf8)) == nil)
    #expect(encryptedStart.range(of: Data(start.identity.requestID.utf8)) == nil)

    // Dropping the actor and reconstructing from disk simulates process loss;
    // no shared in-memory persistence object is involved.
    let signer = SoftwareTerminalSigner()
    let frozen: FrozenProviderTerminal
    do {
        let reopened = try fixture.journal()
        #expect(await reopened.durableStart(for: start.identity.attemptID) == start)
        #expect(try directoryFiles(fixture.terminalReservationsDirectory).count == 1)
        frozen = try await reopened.freezeAndPersistTerminal(
            attemptID: start.identity.attemptID,
            draft: terminalDraft(),
            signer: signer
        )
        #expect(try directoryFiles(fixture.terminalReservationsDirectory).isEmpty)
    }
    #expect(try signer.verifies(frozen))

    let encryptedTerminal = try Data(
        contentsOf: try #require(directoryFiles(fixture.terminalRecordsDirectory).first))
    #expect(encryptedTerminal.range(of: frozen.terminal.canonicalBytes()) == nil)
    #expect(encryptedTerminal.range(of: frozen.seSignature) == nil)

    let crashReopen = try fixture.journal()
    #expect(await crashReopen.pendingTerminalsForReplay() == [frozen])
}

@Test
func terminalReplayRejectsMismatchedAckAndDeletesDurablyAfterMatch() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let start = try fundedStart(attempt: 102)
    do {
        let journal = try fixture.journal()
        _ = try await journal.reserveFundedStart(start)
        let frozen = try await journal.freezeAndPersistTerminal(
            attemptID: start.identity.attemptID,
            draft: terminalDraft(),
            signer: SoftwareTerminalSigner()
        )

        var wrongBytes = frozen.terminalDigest.bytes
        wrongBytes[wrongBytes.startIndex] ^= 0xFF
        let wrongDigest = try TerminalDigest(bytes: wrongBytes)
        await #expect(throws: TerminalJournalError.self) {
            try await journal.acknowledgeTerminal(
                identity: start.identity,
                terminalDigest: wrongDigest
            )
        }
        #expect(await journal.pendingTerminalsForReplay() == [frozen])

        let wrongIdentity = try journalIdentity(attempt: 102, lease: 99_999)
        await #expect(throws: TerminalJournalError.self) {
            try await journal.acknowledgeTerminal(
                identity: wrongIdentity,
                terminalDigest: frozen.terminalDigest
            )
        }
        #expect(await journal.pendingTerminalsForReplay() == [frozen])

        try await journal.acknowledgeTerminal(
            V2TerminalAck(
                identity: start.identity.protocolV2,
                terminalDigest: frozen.terminalDigest.protocolV2,
                disposition: .settled
            ))
        #expect(try directoryFiles(fixture.terminalRecordsDirectory).isEmpty)
    }

    let reopened = try fixture.journal()
    #expect(await reopened.pendingTerminalsForReplay().isEmpty)
    #expect(await reopened.status.occupiedSlots == 0)
}

@Test
func journalLifetimeLockRejectsConcurrentInstances() throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let owner = try fixture.journal()
    #expect(throws: TerminalJournalError.self) {
        _ = try fixture.journal()
    }
    withExtendedLifetime(owner) {}
}

@Test
func connectionProviderIDBindsNewAndPersistedJournalRecords() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal(
        providerID: "22222222-2222-2222-2222-222222222222")
    await #expect(throws: TerminalJournalError.providerIdentityMismatch) {
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 150))
    }
    #expect(try directoryFiles(fixture.terminalRecordsDirectory).isEmpty)

    do {
        let correct = try fixture.journal()
        _ = try await correct.reserveFundedStart(try fundedStart(attempt: 151))
    }
    #expect(throws: TerminalJournalError.providerIdentityMismatch) {
        _ = try fixture.journal(
            providerID: "22222222-2222-2222-2222-222222222222")
    }
}

@Test
func persistedAbortTombstonesRejectProviderIdentityDrift() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let identity = try journalIdentity(attempt: 152)
    do {
        let tombstones = try fixture.tombstones()
        _ = try await tombstones.recordAbort(
            AttemptAbortTombstone(identity: identity)
        )
    }
    #expect(throws: AttemptTombstoneError.providerIdentityMismatch) {
        _ = try AttemptTombstones(
            directory: fixture.root,
            providerID: "22222222-2222-2222-2222-222222222222",
            key: fixture.key
        )
    }
}

@Test
func tombstoneLifetimeLockRejectsConcurrentInstances() throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let owner = try fixture.tombstones()
    #expect(throws: TerminalJournalError.self) {
        _ = try fixture.tombstones()
    }
    withExtendedLifetime(owner) {}
}

@Test
func journalCapacityStopsPaidAdmissionUntilAckFreesSlot() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let capacity = try TerminalJournalCapacity(
        maxEntries: 1,
        maxEncryptedRecordBytes: 16 * 1_024,
        maxTotalReservedBytes: 16 * 1_024
    )
    let journal = try fixture.journal(capacity: capacity)
    let first = try fundedStart(attempt: 103)
    let second = try fundedStart(attempt: 104)

    _ = try await journal.reserveFundedStart(first)
    #expect(await journal.paidAdmissionAllowed == false)
    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.reserveFundedStart(second)
    }

    let terminal = try await journal.freezeAndPersistTerminal(
        attemptID: first.identity.attemptID,
        draft: terminalDraft(),
        signer: SoftwareTerminalSigner()
    )
    #expect(await journal.paidAdmissionAllowed == false)
    try await journal.acknowledgeTerminal(
        identity: first.identity,
        terminalDigest: terminal.terminalDigest
    )
    #expect(await journal.paidAdmissionAllowed)
    #expect(try await journal.reserveFundedStart(second) == .persisted)
}

@Test
func fundedStartPreallocatesTerminalSpaceAndConsumesItOnlyAfterTerminal() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let bytes = 32 * 1_024
    let capacity = try TerminalJournalCapacity(
        maxEntries: 1,
        maxEncryptedRecordBytes: bytes,
        maxTotalReservedBytes: bytes
    )
    let journal = try fixture.journal(capacity: capacity)
    let start = try fundedStart(attempt: 110)
    _ = try await journal.reserveFundedStart(start)

    let reservation = try #require(
        directoryFiles(fixture.terminalReservationsDirectory).first)
    let values = try reservation.resourceValues(
        forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
    #expect(values.fileSize == bytes)
    #expect((values.fileAllocatedSize ?? 0) >= bytes)

    _ = try await journal.freezeAndPersistTerminal(
        attemptID: start.identity.attemptID,
        draft: terminalDraft(),
        signer: SoftwareTerminalSigner()
    )
    #expect(try directoryFiles(fixture.terminalReservationsDirectory).isEmpty)
}

@Test
func preallocationENOSPCDoesNotReturnFundedStartDurability() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let faults = JournalFaultPlan()
    faults.failNext(.preallocate, errno: ENOSPC)
    let journal = try fixture.journal(faults: faults)

    do {
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 111))
        Issue.record("expected ENOSPC")
    } catch let error as TerminalJournalError {
        guard case .systemCall(let operation, let errorNumber) = error else {
            Issue.record("unexpected error \(error)")
            return
        }
        #expect(operation == JournalFaultPoint.preallocate.rawValue)
        #expect(errorNumber == ENOSPC)
    }
    #expect(await journal.status.occupiedSlots == 0)
    #expect(try directoryFiles(fixture.terminalRecordsDirectory).isEmpty)
    #expect(try directoryFiles(fixture.terminalReservationsDirectory).isEmpty)
}

@Test
func reservedInodePersistsTerminalWhenOrdinaryAllocationReturnsENOSPC() throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let faults = JournalFaultPlan()
    let directory = fixture.root.appendingPathComponent(
        "reservation-consumption", isDirectory: true)
    let store = try DurableEncryptedRecordStore(
        directory: directory,
        namespace: "terminal",
        key: fixture.key,
        maximumRecordBytes: 32 * 1_024,
        lockName: ".reservation-consumption.lock",
        faults: faults
    )
    let name = hashedRecordName(fixtureUUID(112))
    let reservation = directory.appendingPathComponent(
        "reservations/\(name).reserve")
    let record = directory.appendingPathComponent("records/\(name).dbtj")

    try store.reserveTerminalSpace(name: name)
    let reservedInode = try inodeNumber(at: reservation)
    try store.write(name: name, plaintext: Data("funded-start".utf8))

    faults.failNext(.newFileAllocation, errno: ENOSPC)
    #expect(
        throws: TerminalJournalError.systemCall(
            operation: JournalFaultPoint.newFileAllocation.rawValue,
            errorNumber: ENOSPC
        )
    ) {
        try store.write(
            name: hashedRecordName(fixtureUUID(113)),
            plaintext: Data("ordinary-allocation".utf8)
        )
    }

    let terminal = Data("terminal-using-reserved-blocks".utf8)
    try store.writeConsumingReservation(name: name, plaintext: terminal)
    #expect(try inodeNumber(at: record) == reservedInode)
    #expect(!FileManager.default.fileExists(atPath: reservation.path))

    let scan = try store.scan()
    #expect(scan.records.count == 1)
    #expect(scan.records.first?.name == name)
    #expect(scan.records.first?.plaintext == terminal)
    #expect(scan.reservationNames.isEmpty)
}

@Test
func durableSyscallFaultPointsNeverReturnAnUnreservedStart() async throws {
    for (index, point) in [
        JournalFaultPoint.write,
        .fileSync,
        .rename,
        .directorySync,
    ].enumerated() {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let faults = JournalFaultPlan()
        faults.failNext(point)
        do {
            let journal = try fixture.journal(faults: faults)
            await #expect(throws: TerminalJournalError.self) {
                _ = try await journal.reserveFundedStart(
                    try fundedStart(attempt: 120 + index))
            }
            #expect(await journal.status.occupiedSlots == 0)
        }
        let reopened = try fixture.journal()
        #expect(await reopened.status.occupiedSlots == 0)
        #expect(await reopened.durableStartsForRecovery().isEmpty)
    }
}

@Test
func terminalReplacementFaultsReopenToExactlyOneDurableObligation() async throws {
    let schedules: [(JournalFaultPoint, Int, expectsTerminal: Bool)] = [
        // Before terminal content or its durable truncate: funded start survives.
        (.write, 1, false),
        (.fileSync, 2, false),
        (.truncate, 0, false),
        // After truncate, the authenticated staged reservation is itself the
        // recovery source and must finish as a terminal without re-signing.
        (.fileSync, 3, true),
        (.link, 0, true),
        (.rename, 1, true),
        (.directorySync, 2, true),
        (.unlink, 0, true),
    ]
    for (index, schedule) in schedules.enumerated() {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let faults = JournalFaultPlan()
        faults.fail(schedule.0, afterSuccessfulCalls: schedule.1)
        let start = try fundedStart(attempt: 140 + index)
        let signer = SoftwareTerminalSigner()
        do {
            let journal = try fixture.journal(faults: faults)
            _ = try await journal.reserveFundedStart(start)
            await #expect(throws: TerminalJournalError.self) {
                _ = try await journal.freezeAndPersistTerminal(
                    attemptID: start.identity.attemptID,
                    draft: terminalDraft(),
                    signer: signer
                )
            }
            #expect(await journal.paidAdmissionAllowed == false)
        }

        let reopened = try fixture.journal()
        let starts = await reopened.durableStartsForRecovery()
        let terminals = await reopened.pendingTerminalsForReplay()
        #expect(starts.count + terminals.count == 1)
        #expect(terminals.count == (schedule.expectsTerminal ? 1 : 0))
        #expect(await reopened.status.occupiedSlots == 1)
        #expect(
            try directoryFiles(fixture.terminalReservationsDirectory).count
                == (starts.isEmpty ? 0 : 1))
        if let terminal = terminals.first {
            let duplicate = try await reopened.freezeAndPersistTerminal(
                attemptID: start.identity.attemptID,
                draft: terminalDraft(),
                signer: signer
            )
            #expect(duplicate == terminal)
            #expect(signer.signCallCount == 1)
        }
    }
}

@Test
func orphanFundedStartCanBecomeReviewRequiredTerminalAndReplay() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let start = try fundedStart(attempt: 130)
    do {
        let journal = try fixture.journal()
        _ = try await journal.reserveFundedStart(start)
    }

    let recovered: FrozenProviderTerminal
    do {
        let reopened = try fixture.journal()
        #expect(await reopened.durableStartsForRecovery() == [start])
        recovered = try await reopened.recoverOrphanedStart(
            attemptID: start.identity.attemptID,
            reason: .providerRestart,
            signer: SoftwareTerminalSigner()
        )
        #expect(recovered.terminal.outcome == .cancelled)
        #expect(recovered.terminal.errorClass == .fault)
        #expect(recovered.reviewRequired)
        #expect(recovered.recoveryReason == OrphanedStartRecoveryReason.providerRestart.rawValue)
        #expect(await reopened.durableStartsForRecovery().isEmpty)
    }

    let replay = try fixture.journal()
    #expect(await replay.pendingTerminalsForReplay() == [recovered])
}

@Test
func tombstoneFullnessParticipatesInPaidAdmission() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let capacity = try TerminalJournalCapacity(
        maxEntries: 1,
        maxEncryptedRecordBytes: TerminalJournalCapacity.minimumEncryptedRecordBytes,
        maxTotalReservedBytes: TerminalJournalCapacity.minimumEncryptedRecordBytes
    )
    let journal = try fixture.journal(capacity: capacity)
    let tombstones = try fixture.tombstones(capacity: capacity)
    let fence = try AttemptAbortTombstone(
        identity: journalIdentity(attempt: 131, generation: 91))
    _ = try await tombstones.recordAbort(fence)

    #expect(
        await journal.paidAdmissionStatus(
            including: tombstones
        ).paidAdmissionAllowed == false)
    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.reserveFundedStart(
            try fundedStart(attempt: 132),
            checking: tombstones
        )
    }

    let proof = try replayFenceProof(id: 904, identity: fence.identity, throughEpoch: .max)
    #expect(
        try await tombstones.expire(
            using: proof, verifiedBy: replayFenceAuthority) == 1)
    #expect(
        try await journal.reserveFundedStart(
            try fundedStart(attempt: 132),
            checking: tombstones
        ) == .persisted)
}

@Test
func capacityRejectsRecordSizeThatCannotGuaranteeFutureTerminalPersistence() {
    #expect(throws: TerminalJournalError.self) {
        _ = try TerminalJournalCapacity(
            maxEntries: 2,
            maxEncryptedRecordBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes - 1,
            maxTotalReservedBytes:
                2 * TerminalJournalCapacity.minimumEncryptedRecordBytes
        )
    }
}

@Test
func journalDuplicateOperationsAreIdempotentAndConflictsFailClosed() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let start = try fundedStart(attempt: 105)
    #expect(try await journal.reserveFundedStart(start) == .persisted)
    let retryWithNewLocalTimestamp = try FundedStartRecord(
        identity: start.identity,
        model: start.model,
        promptTokens: start.promptTokens,
        fundedAtUnixMilliseconds: start.fundedAtUnixMilliseconds + 1
    )
    #expect(
        try await journal.reserveFundedStart(retryWithNewLocalTimestamp)
            == .alreadyPersisted)

    let conflict = try fundedStart(attempt: 105, lease: 88_888)
    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.reserveFundedStart(conflict)
    }

    let signer = SoftwareTerminalSigner()
    let first = try await journal.freezeAndPersistTerminal(
        attemptID: start.identity.attemptID,
        draft: terminalDraft(),
        signer: signer
    )
    let duplicate = try await journal.freezeAndPersistTerminal(
        attemptID: start.identity.attemptID,
        draft: terminalDraft(),
        signer: signer
    )
    #expect(duplicate == first, "duplicate terminal must reuse the persisted signature")

    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.freezeAndPersistTerminal(
            attemptID: start.identity.attemptID,
            draft: terminalDraft(completionTokens: 6),
            signer: signer
        )
    }
    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.reserveFundedStart(start)
    }
}

@Test
func unauthenticatedCorruptionFailsClosedWithoutMovingObligations() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let capacity = try TerminalJournalCapacity(
        maxEntries: 2,
        maxEncryptedRecordBytes: 16 * 1_024,
        maxTotalReservedBytes: 32 * 1_024
    )
    do {
        let journal = try fixture.journal(capacity: capacity)
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 106))
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 107))
    }
    let files = try directoryFiles(fixture.terminalRecordsDirectory).sorted {
        $0.lastPathComponent < $1.lastPathComponent
    }
    #expect(files.count == 2)

    let first = try Data(contentsOf: files[0])
    try first.prefix(9).write(to: files[0], options: .atomic)
    var second = try Data(contentsOf: files[1])
    second[second.index(before: second.endIndex)] ^= 0x80
    try second.write(to: files[1], options: .atomic)

    let namesBefore = try directoryFiles(fixture.terminalRecordsDirectory)
        .map(\.lastPathComponent).sorted()
    #expect(throws: TerminalJournalError.self) {
        _ = try fixture.journal(capacity: capacity)
    }
    #expect(
        try directoryFiles(fixture.terminalRecordsDirectory)
            .map(\.lastPathComponent).sorted() == namesBefore)
    #expect(try directoryFiles(fixture.terminalQuarantineDirectory).isEmpty)
}

@Test
func authenticatedMalformedRecordGetsDurableIndexWithoutMovingCiphertext() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let attemptID = fixtureUUID(108)
    let name = hashedRecordName(attemptID)
    do {
        let store = try DurableEncryptedRecordStore(
            directory: fixture.root.appendingPathComponent("terminals", isDirectory: true),
            namespace: "terminal",
            key: fixture.key,
            maximumRecordBytes: TerminalJournalCapacity.production.maxEncryptedRecordBytes,
            lockName: ".terminal-journal.lock"
        )
        try store.write(
            name: name,
            plaintext: Data(#"{"schema":"authenticated-but-invalid"}"#.utf8)
        )
    }

    let journal = try fixture.journal()
    let status = await journal.status
    #expect(status.quarantinedRecords == 1)
    #expect(status.occupiedSlots == 1)
    #expect(try directoryFiles(fixture.terminalRecordsDirectory).count == 1)
    #expect(try directoryFiles(fixture.terminalQuarantineDirectory).count == 1)
    await #expect(throws: TerminalJournalError.self) {
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 108))
    }
}

@Test
func wrongJournalKeyFailsClosedWithObligationFilesUntouched() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    do {
        let journal = try fixture.journal()
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 109))
    }
    let before = try directoryFiles(fixture.terminalRecordsDirectory)
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    #expect(throws: TerminalJournalError.authenticationFailed) {
        _ = try fixture.journal(key: SymmetricKey(size: .bits256))
    }
    let after = try directoryFiles(fixture.terminalRecordsDirectory)
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    #expect(after.count == before.count)
    #expect(after.map(\.0) == before.map(\.0))
    #expect(zip(after, before).allSatisfy { $0.0.1 == $0.1.1 })
    #expect(try directoryFiles(fixture.terminalQuarantineDirectory).isEmpty)
}

@Test
func aadFilenameMismatchFailsClosedWithoutQuarantine() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    do {
        let journal = try fixture.journal()
        _ = try await journal.reserveFundedStart(try fundedStart(attempt: 1090))
    }
    let original = try #require(directoryFiles(fixture.terminalRecordsDirectory).first)
    let rebound = fixture.terminalRecordsDirectory.appendingPathComponent(
        "\(hashedRecordName(fixtureUUID(1091))).dbtj")
    try FileManager.default.moveItem(at: original, to: rebound)

    #expect(throws: TerminalJournalError.authenticationFailed) {
        _ = try fixture.journal()
    }
    #expect(FileManager.default.fileExists(atPath: rebound.path))
    #expect(try directoryFiles(fixture.terminalQuarantineDirectory).isEmpty)
}

@Test
func orphanAtomicWriteTempIsRemovedOnReopen() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    do {
        let journal = try fixture.journal()
        withExtendedLifetime(journal) {}
    }
    let orphan = fixture.terminalRecordsDirectory.appendingPathComponent(
        "orphan.dbtj.tmp-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: orphan.path, contents: Data("partial".utf8))
    #expect(FileManager.default.fileExists(atPath: orphan.path))

    _ = try fixture.journal()
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}

@Test
func abortTombstoneSurvivesReopenRejectsDelayedStartAndNeedsSafeExpiry() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let identity = try journalIdentity(attempt: 201, generation: 77, epoch: 12)
    let tombstone = try AttemptAbortTombstone(
        identity: identity,
        reason: "hedge_lost",
        createdAtUnixMilliseconds: 1  // Deliberately ancient; age is irrelevant.
    )

    do {
        let store = try fixture.tombstones()
        #expect(try await store.recordAbort(tombstone) == .persisted)
        let duplicateReason = try AttemptAbortTombstone(
            identity: identity,
            reason: "duplicate_abort",
            createdAtUnixMilliseconds: 2
        )
        #expect(try await store.recordAbort(duplicateReason) == .alreadyPersisted)
    }
    let encryptedTombstone = try Data(
        contentsOf: try #require(directoryFiles(fixture.tombstoneRecordsDirectory).first))
    #expect(encryptedTombstone.range(of: Data("hedge_lost".utf8)) == nil)
    #expect(encryptedTombstone.range(of: Data(identity.leaseID.utf8)) == nil)

    let safe = try replayFenceProof(id: 902, identity: identity, throughEpoch: 12)
    do {
        let reopened = try fixture.tombstones()
        #expect(await reopened.contains(attemptID: identity.attemptID))
        await #expect(throws: AttemptTombstoneError.self) {
            try await reopened.validateStartAllowed(identity)
        }

        let unrelatedIdentity = try journalIdentity(attempt: 999, generation: 999)
        let unrelated = try replayFenceProof(
            id: 900,
            identity: unrelatedIdentity,
            throughEpoch: .max
        )
        #expect(
            try await reopened.expire(
                using: unrelated, verifiedBy: replayFenceAuthority) == 0)
        #expect(await reopened.contains(attemptID: identity.attemptID))

        let tooEarly = try replayFenceProof(id: 901, identity: identity, throughEpoch: 11)
        #expect(
            try await reopened.expire(
                using: tooEarly, verifiedBy: replayFenceAuthority) == 0)
        await #expect(throws: AttemptTombstoneError.self) {
            _ = try await reopened.expire(
                using: safe,
                verifiedBy: SoftwareReplayFenceAuthority()
            )
        }
        #expect(await reopened.contains(attemptID: identity.attemptID))
        #expect(
            try await reopened.expire(
                using: safe, verifiedBy: replayFenceAuthority) == 1)
        try await reopened.validateStartAllowed(identity)
        #expect(await reopened.durableReplayFenceProofs().isEmpty)
    }
    let afterDeleteReopen = try fixture.tombstones()
    #expect(await afterDeleteReopen.contains(attemptID: identity.attemptID) == false)
    #expect(await afterDeleteReopen.durableReplayFenceProofs().isEmpty)
}

@Test
func abortTombstoneRejectsAttemptIdentityConflict() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let store = try fixture.tombstones()
    let original = try AttemptAbortTombstone(identity: journalIdentity(attempt: 202))
    _ = try await store.recordAbort(original)

    let conflict = try AttemptAbortTombstone(
        identity: journalIdentity(attempt: 202, lease: 123_456))
    await #expect(throws: AttemptTombstoneError.self) {
        _ = try await store.recordAbort(conflict)
    }
    await #expect(throws: AttemptTombstoneError.self) {
        try await store.validateStartAllowed(conflict.identity)
    }
}

@Test
func tombstoneWriteDirectoryFsyncFaultRequiresCrashReopen() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let faults = JournalFaultPlan()
    faults.failNext(.directorySync)
    let tombstone = try AttemptAbortTombstone(
        identity: journalIdentity(attempt: 205))
    do {
        let store = try fixture.tombstones(faults: faults)
        await #expect(throws: TerminalJournalError.self) {
            _ = try await store.recordAbort(tombstone)
        }
        #expect(await store.paidAdmissionAllowed == false)
    }
    let reopened = try fixture.tombstones()
    #expect(await reopened.contains(attemptID: tombstone.identity.attemptID))
}

@Test
func abortTombstoneCapacityIsBoundedUntilExplicitExpiry() async throws {
    let fixture = try JournalFixture()
    defer { fixture.cleanup() }
    let capacity = try TerminalJournalCapacity(
        maxEntries: 1,
        maxEncryptedRecordBytes:
            TerminalJournalCapacity.minimumEncryptedRecordBytes,
        maxTotalReservedBytes:
            TerminalJournalCapacity.minimumEncryptedRecordBytes
    )
    let store = try fixture.tombstones(capacity: capacity)
    let first = try AttemptAbortTombstone(
        identity: journalIdentity(attempt: 203, generation: 88))
    let second = try AttemptAbortTombstone(
        identity: journalIdentity(attempt: 204, generation: 88))
    _ = try await store.recordAbort(first)
    #expect(await store.status.full)
    await #expect(throws: AttemptTombstoneError.self) {
        _ = try await store.recordAbort(second)
    }

    let proof = try replayFenceProof(
        id: 903,
        identity: first.identity,
        throughEpoch: .max
    )
    #expect(
        try await store.expire(
            using: proof, verifiedBy: replayFenceAuthority) == 1)
    #expect(try await store.recordAbort(second) == .persisted)
}

import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

private final class ReplayFenceTestAuthority:
    CoordinatorReplayFenceProofVerifier, @unchecked Sendable
{
    private let key = P256.Signing.PrivateKey()

    func proof(
        id: Int,
        identity: TerminalAttemptIdentity,
        throughEpoch: UInt64,
        revision: UInt64
    ) throws -> CoordinatorReplayFenceProof {
        let proofID = replayFenceUUID(id)
        let digest = try CoordinatorReplayFenceProof.signingDigest(
            proofID: proofID,
            providerID: identity.providerID,
            providerProcessGeneration: identity.providerProcessGeneration,
            throughSessionEpoch: throughEpoch,
            coordinatorRevision: revision
        )
        return try CoordinatorReplayFenceProof(
            proofID: proofID,
            providerID: identity.providerID,
            providerProcessGeneration: identity.providerProcessGeneration,
            throughSessionEpoch: throughEpoch,
            coordinatorRevision: revision,
            proofDigest: digest,
            coordinatorSignature: try key.signature(
                for: digest.bytes
            ).derRepresentation
        )
    }

    func verifyCoordinatorReplayFenceProof(
        _ proof: CoordinatorReplayFenceProof
    ) throws -> Bool {
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: proof.coordinatorSignature)
        return key.publicKey.isValidSignature(
            signature,
            for: proof.proofDigest.bytes
        )
    }
}

private struct ReplayFenceFixture {
    let root: URL
    let key = SymmetricKey(size: .bits256)
    let providerID = replayFenceUUID(1)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "replay-fence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func store(
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

    var proofRecords: URL {
        root.appendingPathComponent(
            "replay-fences/records",
            isDirectory: true
        )
    }

    var tombstoneRecords: URL {
        root.appendingPathComponent(
            "abort-tombstones/records",
            isDirectory: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Attempt tombstone replay-fence durability")
struct AttemptTombstonesReplayFenceTests {
    @Test("one generation retains only its latest needed proof")
    func latestProofCompactsByGeneration() async throws {
        let fixture = try ReplayFenceFixture()
        defer { fixture.cleanup() }
        let authority = ReplayFenceTestAuthority()
        let store = try fixture.store()
        let first = try replayFenceIdentity(
            providerID: fixture.providerID,
            attempt: 11,
            generation: 7,
            epoch: 1
        )
        let second = try replayFenceIdentity(
            providerID: fixture.providerID,
            attempt: 12,
            generation: 7,
            epoch: 2
        )
        _ = try await store.recordAbort(
            AttemptAbortTombstone(identity: first))
        _ = try await store.recordAbort(
            AttemptAbortTombstone(identity: second))

        let earlier = try authority.proof(
            id: 101,
            identity: first,
            throughEpoch: 1,
            revision: 1
        )
        let later = try authority.proof(
            id: 102,
            identity: second,
            throughEpoch: 2,
            revision: 2
        )
        #expect(
            try await store.persistReplayFenceProof(
                earlier,
                verifiedBy: authority
            ))
        #expect(
            try await store.persistReplayFenceProof(
                later,
                verifiedBy: authority
            ))
        #expect(await store.durableReplayFenceProofs() == [later])
        #expect(try replayFenceFiles(in: fixture.proofRecords).count == 1)

        await #expect(throws: AttemptTombstoneError.self) {
            _ = try await store.persistReplayFenceProof(
                earlier,
                verifiedBy: authority
            )
        }
        #expect(
            try await store.expire(
                using: later,
                verifiedBy: authority
            ) == 2)
        #expect(await store.durableReplayFenceProofs().isEmpty)
        #expect(try replayFenceFiles(in: fixture.proofRecords).isEmpty)
    }

    @Test("unique signed proofs cannot create steady-state disk growth")
    func uniqueProofStressIsBounded() async throws {
        let fixture = try ReplayFenceFixture()
        defer { fixture.cleanup() }
        let capacity = try TerminalJournalCapacity(
            maxEntries: 2,
            maxEncryptedRecordBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes,
            maxTotalReservedBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes * 2
        )
        let authority = ReplayFenceTestAuthority()
        let store = try fixture.store(capacity: capacity)

        for index in 1...100 {
            let identity = try replayFenceIdentity(
                providerID: fixture.providerID,
                attempt: 1_000 + index,
                generation: 2_000 + index,
                epoch: 1
            )
            _ = try await store.recordAbort(
                AttemptAbortTombstone(identity: identity))
            let proof = try authority.proof(
                id: 3_000 + index,
                identity: identity,
                throughEpoch: 1,
                revision: UInt64(index)
            )
            #expect(
                try await store.expire(
                    using: proof,
                    verifiedBy: authority
                ) == 1)
            #expect(await store.durableReplayFenceProofs().isEmpty)
        }

        #expect(try replayFenceFiles(in: fixture.proofRecords).isEmpty)
        #expect(try replayFenceFiles(in: fixture.tombstoneRecords).isEmpty)
    }

    @Test("reopen finishes proof-authorized deletion and prunes proof")
    func interruptedDeletionReconcilesOnReopen() async throws {
        let fixture = try ReplayFenceFixture()
        defer { fixture.cleanup() }
        let authority = ReplayFenceTestAuthority()
        let identity = try replayFenceIdentity(
            providerID: fixture.providerID,
            attempt: 41,
            generation: 42,
            epoch: 9
        )
        let proof = try authority.proof(
            id: 43,
            identity: identity,
            throughEpoch: 9,
            revision: 1
        )

        do {
            let faults = JournalFaultPlan()
            let store = try fixture.store(faults: faults)
            _ = try await store.recordAbort(
                AttemptAbortTombstone(identity: identity))
            faults.failNext(.unlink)
            await #expect(throws: TerminalJournalError.self) {
                _ = try await store.expire(
                    using: proof,
                    verifiedBy: authority
                )
            }
            #expect(await store.contains(attemptID: identity.attemptID))
            #expect(await store.durableReplayFenceProofs() == [proof])
            #expect(try replayFenceFiles(in: fixture.proofRecords).count == 1)
        }

        let reopened = try fixture.store()
        #expect(!(await reopened.contains(attemptID: identity.attemptID)))
        #expect(await reopened.durableReplayFenceProofs().isEmpty)
        #expect(try replayFenceFiles(in: fixture.proofRecords).isEmpty)
        #expect(try replayFenceFiles(in: fixture.tombstoneRecords).isEmpty)
    }
}

private func replayFenceIdentity(
    providerID: String,
    attempt: Int,
    generation: Int,
    epoch: UInt64
) throws -> TerminalAttemptIdentity {
    try TerminalAttemptIdentity(
        providerID: providerID,
        providerProcessGeneration: replayFenceUUID(generation),
        sessionEpoch: epoch,
        requestID: replayFenceUUID(10_000 + attempt),
        attemptID: replayFenceUUID(attempt),
        reservationID: replayFenceUUID(20_000 + attempt),
        leaseID: replayFenceUUID(30_000 + attempt)
    )
}

private func replayFenceUUID(_ value: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012x", value)
}

private func replayFenceFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
}

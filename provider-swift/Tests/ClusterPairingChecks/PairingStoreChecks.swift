import Darwin
import Foundation
@testable import DarkbloomClusterSecurity

/// The pairing store's files, its rollback and unpair, and the gate.
extension PairingCheck {
    static func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    static func pairedOutcomes() -> (ClusterPairingOutcome, ClusterPairingOutcome) {
        let run = runInMemory(TestPairing.participant(SoftwareIdentity(), interface: "en7"), TestPairing.participant(SoftwareIdentity(), interface: "en6"))
        return (run.outcomes[.listener]!, run.outcomes[.connector]!)
    }

    enum Loaded: Equatable {
        case empty, records(ClusterPairingRecords), unsafe, failed
        var records: ClusterPairingRecords? { if case .records(let value) = self { return value }; return nil }
    }

    static func loaded(_ store: ClusterPairingStore) -> Loaded {
        do { return try store.load().map(Loaded.records) ?? .empty }
        catch ClusterPairingStoreError.unsafe { return .unsafe } catch { return .failed }
    }

    static func storeFiles() {
        let home = freshDirectory("store")
        let store = ClusterPairingStore(directory: home.appendingPathComponent("cluster-pairing"))
        expectEqual(loaded(store), .empty, "an empty store reads as never paired")
        let (outcome, _) = pairedOutcomes()
        let edge = UUID()
        guard (try? store.commit(outcome, edgeID: edge)) != nil else { expect(false, "commit"); return }
        expectEqual(mode(store.directory.path), 0o700, "pairing directory is 0700")
        expectEqual(mode(store.recordsFile.path), 0o600, "pairings.json is 0600")
        expectEqual(mode(store.secretFile(peerPin: outcome.peer.pin).path), 0o600, "edge secret is 0600")
        expectEqual(mode(store.auditFile.path), 0o600, "audit log is 0600")
        guard let records = loaded(store).records, let record = records.pairing(peerPin: outcome.peer.pin) else { expect(false, "load"); return }
        expectEqual(records.localPin, outcome.localPin, "records name this Mac's pin")
        expectEqual(record.peerIdentityKey, outcome.peer.identityKey.base64EncodedString(), "pinned key stored")
        expectEqual(record.roster.members, outcome.rosterMembers, "roster stored")
        expectEqual(record.rosterSHA256, outcome.rosterSHA256, "roster hash stored")
        expectEqual(record.link.edgeID, edge.uuidString.lowercased(), "edge stored")
        expectEqual(record.link.linkEpoch, outcome.linkEpoch.uuidString.lowercased(), "epoch stored")
        expectEqual(record.link.localInterface, "en7", "local interface"); expectEqual(record.link.peerInterface, "en6", "peer interface")
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "edge secret reads back")
        let recordsText = String(decoding: FileManager.default.contents(atPath: store.recordsFile.path) ?? Data(), as: UTF8.self)
        let auditText = String(decoding: FileManager.default.contents(atPath: store.auditFile.path) ?? Data(), as: UTF8.self)
        let secretHex = outcome.edgeSecret.map { String(format: "%02x", $0) }.joined()
        expect(!recordsText.contains(secretHex) && !auditText.contains(secretHex), "the secret is only in its own file")
        expect(!auditText.contains(outcome.code), "the audit never names the code")
        // Widened modes and links are refused, not repaired.
        chmod(store.recordsFile.path, 0o644)
        expectEqual(loaded(store), .unsafe, "a group-readable pairings.json is refused as unsafe")
        chmod(store.recordsFile.path, 0o600)
        expect(loaded(store).records != nil, "readable again at 0600")
        chmod(store.directory.path, 0o755)
        expectEqual(loaded(store), .unsafe, "a world-readable directory is refused")
        chmod(store.directory.path, 0o700)
        let moved = store.recordsFile.path + ".real"
        rename(store.recordsFile.path, moved)
        symlink(moved, store.recordsFile.path)
        expectEqual(loaded(store), .unsafe, "a symbolic link in place of pairings.json is refused")
        unlink(store.recordsFile.path); rename(moved, store.recordsFile.path)
        // A pairing under a new local identity replaces the old set.
        let (fresh, _) = pairedOutcomes()
        _ = try? store.commit(fresh, edgeID: UUID())
        let replaced = loaded(store).records
        expectEqual(replaced?.localPin, fresh.localPin, "a new local identity replaces the records")
        expectEqual(replaced?.pairings.count, 1, "old pins are dropped")
    }

    static func storeRollback() {
        let home = freshDirectory("rollback")
        let store = ClusterPairingStore(directory: home.appendingPathComponent("cluster-pairing"))
        let (first, _) = pairedOutcomes()
        _ = try? store.commit(first, edgeID: UUID())
        let before = loaded(store)
        // Re-pairing the same two keys: a second outcome for the same peer, then rolled back.
        let run = runInMemory(
            ClusterPairingParticipant(identity: SoftwareIdentity(), name: "x", interface: "lo0", attestation: { _ in Data() }),
            ClusterPairingParticipant(identity: SoftwareIdentity(), name: "y", interface: "lo0", attestation: { _ in Data() }))
        expect(run.outcomes.isEmpty, "(sanity) a ceremony with bad attestations completes nothing")
        let token = try? store.commit(first, edgeID: UUID())
        expect(token != nil, "a second commit for the same peer")
        if let token { store.rollback(token) }
        expectEqual(loaded(store), before, "rollback restores the earlier records exactly")
        let secret = before.records.flatMap { try? store.edgeSecret(for: $0.pairings[0]) }
        expectEqual(secret, first.edgeSecret, "and the earlier edge secret")
        // Rollback of a first pairing leaves nothing.
        let other = ClusterPairingStore(directory: freshDirectory("rollback-first").appendingPathComponent("cluster-pairing"))
        if let token = try? other.commit(first, edgeID: UUID()) { other.rollback(token) }
        expectEqual(loaded(other), .empty, "rolling back a first pairing leaves no records")
        expect(!FileManager.default.fileExists(atPath: other.secretFile(peerPin: first.peer.pin).path), "and no edge secret")
        // Unpair.
        let removed = try? store.forget(peerPin: first.peer.pin)
        expectEqual(removed?.peerPin, first.peer.pin, "unpair returns the record")
        expectEqual(loaded(store), .empty, "no records left")
        expect(!FileManager.default.fileExists(atPath: store.secretFile(peerPin: first.peer.pin).path), "edge secret removed")
        expect((try? store.forget(peerPin: first.peer.pin)) == nil, "unpairing twice is refused")
        let audit = String(decoding: FileManager.default.contents(atPath: store.auditFile.path) ?? Data(), as: UTF8.self)
        for event in ["pair_stored", "rollback", "unpaired"] { expect(audit.contains("\"event\":\"\(event)\""), "audit names \(event)") }
    }

    final class Clock: @unchecked Sendable {
        var now: Double = 1_000_000
    }

    static func gateLockout() {
        let clock = Clock()
        let directory = freshDirectory("gate").appendingPathComponent("cluster-pairing")
        let store = ClusterPairingStore(directory: directory, clock: { clock.now })
        expect((try? store.checkGate()) != nil, "open at first")
        expect(store.recordFailure(.declinedLocally) == nil, "first failure")
        clock.now += 10
        expect(store.recordFailure(.commitmentMismatch) == nil, "second failure")
        clock.now += 10
        let until = store.recordFailure(.declinedByPeer)
        expectEqual(until, clock.now + ClusterPairingPolicy.lockoutSeconds, "third failure starts a 600 s lockout")
        do { try store.checkGate(); expect(false, "locked") } catch ClusterPairingError.lockedOut(let end) {
            expectEqual(end, until!, "lockout end reported")
        } catch { expect(false, "lockout error") }
        expectEqual(mode(directory.appendingPathComponent("gate.json").path), 0o600, "gate state is 0600")
        let restarted = ClusterPairingStore(directory: directory, clock: { clock.now })
        expect((try? restarted.checkGate()) == nil, "a restart does not lift the lockout")
        clock.now += ClusterPairingPolicy.lockoutSeconds + 1
        expect((try? restarted.checkGate()) != nil, "open again after 600 s")
        expect(restarted.recordFailure(.declinedLocally) == nil, "a fresh count after the lockout")
        clock.now += ClusterPairingPolicy.lockoutSeconds + 1
        expect(restarted.recordFailure(.declinedLocally) == nil, "failures older than the window drop off")
        expect(restarted.recordFailure(.declinedLocally) == nil, "two in the window")
        restarted.recordSuccess()
        expect(restarted.recordFailure(.declinedLocally) == nil, "a success clears the count")
        let audit = String(decoding: FileManager.default.contents(atPath: directory.appendingPathComponent("audit.jsonl").path) ?? Data(), as: UTF8.self)
        expect(audit.contains("\"event\":\"lockout\""), "audit names the lockout")
    }

    static func offerRateLimit() {
        var bucket = ClusterPairingOfferBucket()
        let second: UInt64 = 1_000_000_000
        expect(bucket.allow(nowNanoseconds: 10 * second), "first offer")
        expect(bucket.allow(nowNanoseconds: 10 * second), "second offer")
        expect(bucket.allow(nowNanoseconds: 10 * second), "third offer (burst of 3)")
        expect(!bucket.allow(nowNanoseconds: 10 * second), "fourth at once is refused")
        expect(!bucket.allow(nowNanoseconds: 12 * second), "still refused 2 s later")
        expect(bucket.allow(nowNanoseconds: 15 * second), "one more after 5 s")
        expect(!bucket.allow(nowNanoseconds: 15 * second), "and only one")
        expect(bucket.allow(nowNanoseconds: 60 * second) && bucket.allow(nowNanoseconds: 60 * second) && bucket.allow(nowNanoseconds: 60 * second),
               "refilled to the burst")
        expect(!bucket.allow(nowNanoseconds: 60 * second), "never above the burst")
        expect(!bucket.allow(nowNanoseconds: 1 * second), "a clock going backwards grants nothing")
    }
}

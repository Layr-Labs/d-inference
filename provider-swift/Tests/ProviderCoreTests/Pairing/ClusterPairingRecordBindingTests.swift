import Darwin
import Foundation
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

/// `pairings.json` against the app's own Keychain: each pairing's record is kept there as a digest beside its link
/// key, so a record changed in the file is refused, and a key file put beside a made-up record is never moved in once
/// the store is bound. Pairings an earlier release made keep working across the update. A stand-in vault replaces the
/// Keychain (test binaries have no keychain-access-groups entitlement).
@Suite("Cluster pairing records bound to the Keychain", .serialized)
struct ClusterPairingRecordBindingTests {
    typealias Vault = ClusterLinkKeyKeychainTests.Vault
    typealias SoftwareSigner = ClusterPairingProviderTests.SoftwareSigner

    /// A pairing of two stand-in Macs; the first Mac's store, its vault and its record.
    private func paired() throws -> (store: ClusterPairingStore, vault: Vault, record: ClusterPairingRecord) {
        let vault = Vault()
        let store = ClusterLinkKeyKeychainTests.store(vault)
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(),
                                                               stores: (store, ClusterLinkKeyKeychainTests.store(Vault())))
        return (store, vault, record)
    }

    /// `pairings.json` as JSON, changed by `change` and written back as an owner-only file, as a program other than
    /// Darkbloom could.
    private func edit(_ store: ClusterPairingStore, _ change: (inout [String: Any]) -> Void) throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.recordsFile)) as? [String: Any])
        change(&json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        unlink(store.recordsFile.path)
        #expect(FileManager.default.createFile(atPath: store.recordsFile.path, contents: data, attributes: [.posixPermissions: 0o600]))
    }

    /// Changes the first pairing of `json` with `change`.
    private func pairing(_ json: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var pairings = json["pairings"] as? [[String: Any]], !pairings.isEmpty else { return }
        change(&pairings[0])
        json["pairings"] = pairings
    }

    /// The pairing made over: another Mac's key and pin in place of the paired one's (its roster entry too, so the
    /// record is well formed), and a key file of its own beside the records.
    private func forge(_ store: ClusterPairingStore, _ json: inout [String: Any]) -> (pin: String, file: String) {
        let key = SoftwareSigner().x963, pin = ClusterPairingPin.of(identityKey: key)
        let file = store.directory.appendingPathComponent("edge-\(pin.prefix(16)).secret").path
        pairing(&json) { record in
            let old = record["peerPin"] as? String
            record["peerPin"] = pin
            record["peerIdentityKey"] = key.base64EncodedString()
            if var link = record["link"] as? [String: Any] { link["secretFile"] = file; record["link"] = link }
            if var roster = record["roster"] as? [String: Any], var members = roster["members"] as? [[String: Any]] {
                for index in members.indices where members[index]["pin"] as? String == old {
                    members[index]["pin"] = pin
                    members[index]["se_public_key"] = key.base64EncodedString()
                }
                roster["members"] = members
                record["roster"] = roster
            }
        }
        #expect(FileManager.default.createFile(atPath: file, contents: ClusterLinkKeyKeychainTests.hexLine(Data(repeating: 0x5a, count: 32)),
                                               attributes: [.posixPermissions: 0o600]))
        return (pin, file)
    }

    /// A record changed in `pairings.json` (here the other Mac's name and its port) is not the one this Mac stored
    /// with the pairing's link key: its key is not given for it.
    @Test func aPairingRecordChangedInTheFileGetsNoLinkKey() throws {
        let (store, vault, record) = try paired()
        #expect(try store.edgeSecret(for: record) == vault.item(record.peerPin)?.secret)
        try edit(store) { json in
            pairing(&json) { record in
                record["peerName"] = "another Mac"
                if var link = record["link"] as? [String: Any] { link["peerInterface"] = "en9"; record["link"] = link }
            }
        }
        let edited = try #require(try store.load()?.pairing(peerPin: record.peerPin))
        #expect(edited != record && edited.link.linkEpoch == record.link.linkEpoch)
        #expect(throws: ClusterPairingStoreError.recordChanged) { try store.edgeSecret(for: edited) }
        #expect(ClusterPairingStoreError.recordChanged.description.contains("pair again"))
    }

    /// A made-up pairing (another Mac's key and pin) with a key file of its own beside the records: once the store is
    /// bound, the file is not moved into the Keychain and the made-up pairing has no key.
    @Test func aKeyFileBesideAMadeUpRecordIsNotMovedIn() throws {
        let (store, vault, record) = try paired()
        _ = try store.edgeSecret(for: record)
        var forged: (pin: String, file: String) = ("", "")
        try edit(store) { json in forged = forge(store, &json) }
        let madeUp = try #require(try store.load()?.pairing(peerPin: forged.pin))
        #expect(throws: ClusterPairingStoreError.linkKeyMissing) { try store.edgeSecret(for: madeUp) }
        #expect(vault.item(forged.pin) == nil, "nothing went into the Keychain")
        #expect(FileManager.default.fileExists(atPath: forged.file), "the file is left as it is")
    }

    /// The last unpairing's sweep of the store's Keychain items keeps the store bound: a made-up pairing and its key
    /// file put in afterwards are not moved in either.
    @Test func theLastUnpairingKeepsTheStoreBound() throws {
        let (store, vault, record) = try paired()
        _ = try store.edgeSecret(for: record)
        let saved = try Data(contentsOf: store.recordsFile)
        _ = try store.forget(peerPin: record.peerPin)
        #expect(vault.item(record.peerPin) == nil)
        #expect(FileManager.default.createFile(atPath: store.recordsFile.path, contents: saved, attributes: [.posixPermissions: 0o600]))
        var forged: (pin: String, file: String) = ("", "")
        try edit(store) { json in forged = forge(store, &json) }
        let madeUp = try #require(try store.load()?.pairing(peerPin: forged.pin))
        #expect(throws: ClusterPairingStoreError.linkKeyMissing) { try store.edgeSecret(for: madeUp) }
        #expect(vault.item(forged.pin) == nil)
    }

    /// A pairing an earlier release made (its link key's item only, no record kept) keeps working after the update: the
    /// first read keeps its record, and the link key's item keeps the binding an earlier release reads, so a rollback
    /// to it still links. Afterwards a change to the record is refused.
    @Test func aPairingFromAnEarlierReleaseKeepsWorkingAndIsBoundOnce() throws {
        let (store, vault, record) = try paired()
        let secret = try #require(vault.item(record.peerPin)?.secret)
        // What an earlier release leaves: no record item, no mark.
        _ = vault.delete(peerPin: "record-" + record.peerPin)
        _ = vault.delete(peerPin: "pairing-records-bound")
        #expect(try store.edgeSecret(for: record) == secret, "the pair keeps linking")
        #expect(vault.item(record.peerPin)?.binding == "link-epoch \(record.link.linkEpoch) edge \(record.link.edgeID)",
                "the link key's item keeps the binding an earlier release reads after a rollback")
        #expect(try store.edgeSecret(for: record) == secret, "and again")
        try edit(store) { json in pairing(&json) { $0["peerName"] = "another Mac" } }
        let edited = try #require(try store.load()?.pairing(peerPin: record.peerPin))
        #expect(throws: ClusterPairingStoreError.recordChanged) { try store.edgeSecret(for: edited) }
    }

    /// The other Mac pairs again (a new ceremony): the new record is kept with the new link key, and reads.
    @Test func pairingAgainKeepsTheNewRecord() throws {
        let vault = Vault()
        let store = ClusterLinkKeyKeychainTests.store(vault)
        let a = SoftwareSigner(), b = SoftwareSigner()
        let (first, _) = try ClusterPairingProviderTests.pair(a, b, stores: (store, ClusterLinkKeyKeychainTests.store(Vault())))
        _ = try store.edgeSecret(for: first)
        let (second, _) = try ClusterPairingProviderTests.pair(a, b, stores: (store, ClusterLinkKeyKeychainTests.store(Vault())))
        #expect(second.link.linkEpoch != first.link.linkEpoch)
        #expect(try store.edgeSecret(for: second) == vault.item(second.peerPin)?.secret)
    }
}

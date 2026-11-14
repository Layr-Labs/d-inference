import Darwin
import Foundation
import Security
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

/// The pairing's link key in the data-protection Keychain, from the provider's side: the install's vault, the store
/// every command opens, a saved setup's secret name, the start's check, `cluster pair --status`, and the rollback path
/// to 0.10.12. A stand-in vault replaces the Keychain (test binaries have no keychain-access-groups entitlement).
@Suite("Cluster link key in the Keychain", .serialized)
struct ClusterLinkKeyKeychainTests {
    typealias SoftwareSigner = ClusterPairingProviderTests.SoftwareSigner

    final class Vault: ClusterEdgeSecretVault, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: ClusterEdgeSecretItem] = [:]
        private var _locked = false
        var locked: Bool { get { lock.withLock { _locked } } set { lock.withLock { _locked = newValue } } }
        func item(_ pin: String) -> ClusterEdgeSecretItem? { lock.withLock { items[pin] } }

        func read(peerPin: String) -> ClusterEdgeSecretVaultRead {
            lock.withLock { _locked ? .failed(.locked) : items[peerPin].map(ClusterEdgeSecretVaultRead.found) ?? .absent }
        }
        func add(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if _locked { return .failed(.locked) }
                if items[peerPin] != nil { return .exists }
                items[peerPin] = item; return .done
            }
        }
        func replace(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if _locked { return .failed(.locked) }
                guard items[peerPin] != nil else { return .absent }
                items[peerPin] = item; return .done
            }
        }
        func delete(peerPin: String) -> ClusterEdgeSecretVaultWrite {
            lock.withLock { if _locked { return .failed(.locked) }; items[peerPin] = nil; return .done }
        }
        func protection(peerPin: String) -> Result<ClusterEdgeSecretItemProtection?, ClusterEdgeSecretVaultFailure> {
            lock.withLock {
                if _locked { return .failure(.locked) }
                return .success(items[peerPin].map {
                    ClusterEdgeSecretItemProtection(accessGroup: "TEST.group", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                                                    synchronizable: false, binding: $0.binding)
                })
            }
        }
    }

    static func store(_ vault: Vault?) -> ClusterPairingStore {
        let plain = ClusterPairingProviderTests.temporaryStore()
        return ClusterPairingStore(directory: plain.directory, vault: vault)
    }

    static func hexLine(_ secret: Data) -> Data { Data((secret.map { String(format: "%02x", $0) }.joined() + "\n").utf8) }

    static func error(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return "\(error)" }
    }

    @Test func theInstallKeepsItsOwnItemsInTheAppsAccessGroup() throws {
        let production = ClusterKeychainEdgeSecretVault.install(environment: .prod, processEnvironment: [:])
        #expect(production.service == "io.darkbloom.cluster-pairing.edge-secret")
        #expect(production.accessGroup == PersistentEnclaveKey.defaultAccessGroup)
        let devnet = ClusterKeychainEdgeSecretVault.install(environment: .dev, processEnvironment: [:])
        #expect(devnet.service == "io.darkbloom.dev.cluster-pairing.edge-secret")
        #expect(devnet.accessGroup == PersistentEnclaveKey.defaultAccessGroup)
        #expect(ClusterKeychainEdgeSecretVault.install(environment: .prod,
            processEnvironment: ["DARKBLOOM_KEYCHAIN_ACCESS_GROUP": "TEAM.io.example"]).accessGroup == "TEAM.io.example",
            "the SE key's override applies to the link keys too")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("link-key-home-\(UUID().uuidString)")
        let store = ClusterPairingStore.default(home: home, environment: .dev)
        #expect((store.vault as? ClusterKeychainEdgeSecretVault)?.service == devnet.service,
                "every command and service opens the store with the install's vault")
    }

    @Test func aSetupNamingAPairingReadsItsKeyFromTheKeychain() throws {
        let vault = Vault()
        let stores = (Self.store(vault), ClusterPairingProviderTests.temporaryStore())
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(), stores: stores)
        let path = record.link.secretFile, directory = stores.0.directory
        #expect(!FileManager.default.fileExists(atPath: path), "the pairing wrote no secret file")
        let item = try #require(vault.item(record.peerPin))
        #expect(try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vault: vault) == item.secret)
        #expect(try DistributedInstalledLinkSecret.requirePresent(path, pairingDirectory: directory, vault: vault))
        try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vault: vault)
        // A restart, and no login since: the start and the link both say to log in, and nothing changes.
        vault.locked = true
        for refusal in [Self.error { try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vault: vault) },
                        Self.error { try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vault: vault) }] {
            #expect(refusal?.contains("Log in to this Mac once since it started") == true, "\(String(describing: refusal))")
        }
        vault.locked = false
        #expect(try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vault: vault) == item.secret, "after the login")
        // Unpaired: the start names the unpairing.
        _ = try stores.0.forget(peerPin: record.peerPin)
        #expect(vault.item(record.peerPin) == nil, "unpairing deleted the item")
        for refusal in [Self.error { try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vault: vault) },
                        Self.error { try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vault: vault) }] {
            #expect(refusal?.contains("the Macs were unpaired") == true, "\(String(describing: refusal))")
        }
    }

    @Test func aSetupFrom0_10_12MovesItsFileIntoTheKeychain() throws {
        let stores = (ClusterPairingProviderTests.temporaryStore(), ClusterPairingProviderTests.temporaryStore())
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(), stores: stores)
        let path = record.link.secretFile
        let legacy = try #require(FileManager.default.contents(atPath: path), "0.10.12's code path wrote its file")
        let vault = Vault()
        try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: stores.0.directory, vault: vault)
        let secret = try DistributedInstalledLinkSecret.read(path, pairingDirectory: stores.0.directory, vault: vault)
        #expect(Self.hexLine(secret) == legacy)
        #expect(vault.item(record.peerPin)?.secret == secret, "the first read moved it into the Keychain")
        #expect(!FileManager.default.fileExists(atPath: path), "and removed the file")
    }

    @Test func anyOtherSecretIsStillAPrivateFile() throws {
        let root = ClusterPairingProviderTests.temporaryStore().directory.deletingLastPathComponent()
        let file = root.appendingPathComponent("qualification.secret")
        let secret = Data((0..<32).map { UInt8($0) | 0x10 })
        FileManager.default.createFile(atPath: file.path, contents: Self.hexLine(secret), attributes: [.posixPermissions: 0o600])
        let vault = Vault()
        let pairing = root.appendingPathComponent("cluster-pairing")
        #expect(try DistributedInstalledLinkSecret.read(file.path, pairingDirectory: pairing, vault: vault) == secret)
        #expect(try !DistributedInstalledLinkSecret.requirePresent(file.path, pairingDirectory: pairing, vault: vault))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(file.path, in: pairing))
        #expect(ClusterLinkControlAttachment.namesPairingSecret(pairing.appendingPathComponent("edge-0123456789abcdef.secret").path, in: pairing))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(pairing.appendingPathComponent("edge-0123.secret").path, in: pairing))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(root.appendingPathComponent("other/edge-0123456789abcdef.secret").path, in: pairing),
                "only this install's store names a pairing's secret")
        let missing = root.appendingPathComponent("gone.secret").path
        let refusal = Self.error { try DistributedInstalledValidation.linkSecretMetadata(missing, pairingDirectory: pairing, vault: vault) }
        #expect(refusal != nil && refusal?.contains("unpaired") == false)
    }

    @Test func pairStatusSaysWhereTheKeyIsWithoutIt() {
        let protection = ClusterEdgeSecretItemProtection(accessGroup: "SLDQ2GJ6TL.io.darkbloom.provider",
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, synchronizable: false, binding: "b")
        #expect(ClusterPairCommandLine.linkKeyWords(.keychain(protection))
            == "in this Mac's Keychain (this Mac only, readable after its first unlock, not synchronised; access group SLDQ2GJ6TL.io.darkbloom.provider)")
        #expect(ClusterPairCommandLine.linkKeyWords(.keychainLocked).contains("locked until someone logs in"))
        #expect(ClusterPairCommandLine.linkKeyWords(.missing).contains("pair again"))
        #expect(ClusterPairCommandLine.linkKeyWords(.file).contains("owner-only file"))
    }

    @Test func aRollbackWritesTheLinkKeysBackForTheOlderRelease() async throws {
        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }
        let vault = Vault()
        let store = ClusterPairingStore(directory: installed.fixture.installRoot.appendingPathComponent("cluster-pairing"), vault: vault)
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(),
                                                               stores: (store, ClusterPairingProviderTests.temporaryStore()))
        let secret = try #require(vault.item(record.peerPin)?.secret)
        #expect(!FileManager.default.fileExists(atPath: record.link.secretFile))

        let session = try installed.updater.beginUpdateSession(operation: "test-rollback")
        defer { session.release() }
        session.linkKeyVault = vault
        try session.recover(now: 500)
        #expect(try session.rollback(now: 500, reason: "operator rollback") == "1.0.0")
        #expect(try installed.liveRelease() == "1.0.0")
        #expect(FileManager.default.contents(atPath: record.link.secretFile) == Self.hexLine(secret),
                "the rollback wrote 0.10.12's file back")
        var info = stat()
        let found = lstat(record.link.secretFile, &info) == 0
        #expect(found && info.st_mode & 0o777 == 0o600, "owner-only")
        #expect(try ClusterPairingStore(directory: store.directory).edgeSecret(for: record) == secret,
                "0.10.12's way of reading gets the key")
        #expect(vault.item(record.peerPin)?.secret == secret, "the item stays for the next update")
    }
}

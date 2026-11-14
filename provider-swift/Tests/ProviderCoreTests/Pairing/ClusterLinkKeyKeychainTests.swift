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
        func deleteAll() -> ClusterEdgeSecretVaultWrite {
            lock.withLock { if _locked { return .failed(.locked) }; items = [:]; return .done }
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

    @Test func eachStoreKeepsItsOwnItemsInTheAppsAccessGroup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("link-key-home-\(UUID().uuidString)")
        let directory = ClusterUserPaths.pairingDirectory(home: home, environment: .prod)
        let production = ClusterKeychainEdgeSecretVault.install(pairingDirectory: directory, environment: .prod, processEnvironment: [:])
        let tag = ClusterKeychainEdgeSecretVault.storeTag(directory)
        #expect(tag.count == 12 && tag.allSatisfy(\.isHexDigit))
        #expect(production.service == "io.darkbloom.cluster-pairing.edge-secret." + tag)
        #expect(production.accessGroup == PersistentEnclaveKey.defaultAccessGroup)
        let devnet = ClusterKeychainEdgeSecretVault.install(pairingDirectory: directory, environment: .dev, processEnvironment: [:])
        #expect(devnet.service == "io.darkbloom.dev.cluster-pairing.edge-secret." + tag, "another install, another service")
        let otherHome = ClusterKeychainEdgeSecretVault.install(
            pairingDirectory: ClusterUserPaths.pairingDirectory(home: home.appendingPathComponent("second"), environment: .prod),
            environment: .prod, processEnvironment: [:])
        #expect(otherHome.service != production.service, "another store of the same build, another service")
        #expect(ClusterKeychainEdgeSecretVault.install(pairingDirectory: URL(fileURLWithPath: directory.path + "/"), environment: .prod,
            processEnvironment: [:]).service == production.service, "the same store, however its path is spelled")
        #expect(ClusterKeychainEdgeSecretVault.install(pairingDirectory: directory, environment: .prod,
            processEnvironment: ["DARKBLOOM_KEYCHAIN_ACCESS_GROUP": "TEAM.io.example"]).accessGroup == "TEAM.io.example",
            "the SE key's override applies to the link keys too")
        let store = ClusterPairingStore.default(home: home, environment: .dev)
        #expect((store.vault as? ClusterKeychainEdgeSecretVault)?.service == devnet.service,
                "every command and service opens the store with its own vault")
    }

    /// The store's tag is its real path: the same before and after its folder exists, through a linked parent, and for
    /// `/var/…` and `/private/var/…` (the first pairing opens the store before `commit` creates the folder).
    @Test func aStoresTagIsItsRealPathBeforeAndAfterItsFolderExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("link-key-tag-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real-home")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        let viaLink = ClusterUserPaths.pairingDirectory(home: linked, environment: .prod)
        let direct = ClusterUserPaths.pairingDirectory(home: real, environment: .prod)
        let privateSpelling = URL(fileURLWithPath: "/private" + direct.path)
        let before = ClusterKeychainEdgeSecretVault.storeTag(direct)
        #expect(ClusterKeychainEdgeSecretVault.storeTag(viaLink) == before, "through a linked home, before the folder exists")
        #expect(!direct.path.hasPrefix("/var/") || ClusterKeychainEdgeSecretVault.storeTag(privateSpelling) == before,
                "/var and /private/var")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        #expect(ClusterKeychainEdgeSecretVault.storeTag(direct) == before, "the folder created")
        #expect(ClusterKeychainEdgeSecretVault.storeTag(viaLink) == before, "through the link, after")
        #expect(ClusterKeychainEdgeSecretVault.realPath(viaLink) == ClusterKeychainEdgeSecretVault.realPath(direct))
    }

    /// The release constant follows the release this ships in: once the changelog entry is rendered into a release's
    /// section, that release must be `firstKeychainRelease` (a later ship would otherwise leave a rollback to a release
    /// that reads only files without its keys).
    @Test func theFirstKeychainReleaseIsTheReleaseThatShipsIt() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let entry = "### Cluster pairing: the link key in the Keychain"
        var release: String?
        for line in changelog.components(separatedBy: "\n") {
            if line.hasPrefix("## v") { release = line.dropFirst(4).split(separator: " ").first.map(String.init) }
            if line == entry { break }
        }
        if changelog.components(separatedBy: "\n").contains(entry) {
            #expect(release == ClusterLinkKeyRollback.firstKeychainRelease,
                    "the entry is in v\(release ?? "?")'s section: set ClusterLinkKeyRollback.firstKeychainRelease to it")
        } else {
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("changelog.d/cluster-link-key-keychain.md").path),
                    "the entry is neither rendered nor pending: keep this test's heading in step with it")
        }
        #expect(SemanticVersion(ClusterLinkKeyRollback.firstKeychainRelease)! <= SemanticVersion(ProviderCore.version)!)
    }

    @Test func aSetupNamingAPairingReadsItsKeyFromTheKeychain() throws {
        let vault = Vault()
        let stores = (Self.store(vault), ClusterPairingProviderTests.temporaryStore())
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(), stores: stores)
        let path = record.link.secretFile, directory = stores.0.directory
        #expect(!FileManager.default.fileExists(atPath: path), "the pairing wrote no secret file")
        let item = try #require(vault.item(record.peerPin))
        #expect(try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vaults: { _ in vault }) == item.secret)
        #expect(try DistributedInstalledLinkSecret.requirePresent(path, pairingDirectory: directory, vaults: { _ in vault }))
        try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vaults: { _ in vault })
        // A restart, and no login since: the start and the link both say to log in, and nothing changes.
        vault.locked = true
        for refusal in [Self.error { try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vaults: { _ in vault }) },
                        Self.error { try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vaults: { _ in vault }) }] {
            #expect(refusal?.contains("Log in to this Mac once after its restart") == true, "\(String(describing: refusal))")
        }
        vault.locked = false
        #expect(try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vaults: { _ in vault }) == item.secret, "after the login")
        // Unpaired: the start names the unpairing.
        _ = try stores.0.forget(peerPin: record.peerPin)
        #expect(vault.item(record.peerPin) == nil, "unpairing deleted the item")
        for refusal in [Self.error { try DistributedInstalledLinkSecret.read(path, pairingDirectory: directory, vaults: { _ in vault }) },
                        Self.error { try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: directory, vaults: { _ in vault }) }] {
            #expect(refusal?.contains("the Macs were unpaired") == true, "\(String(describing: refusal))")
        }
    }

    @Test func aSetupFrom0_10_12MovesItsFileIntoTheKeychain() throws {
        let stores = (ClusterPairingProviderTests.temporaryStore(), ClusterPairingProviderTests.temporaryStore())
        let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(), stores: stores)
        let path = record.link.secretFile
        let legacy = try #require(FileManager.default.contents(atPath: path), "0.10.12's code path wrote its file")
        let vault = Vault()
        try DistributedInstalledValidation.linkSecretMetadata(path, pairingDirectory: stores.0.directory, vaults: { _ in vault })
        let secret = try DistributedInstalledLinkSecret.read(path, pairingDirectory: stores.0.directory, vaults: { _ in vault })
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
        #expect(try DistributedInstalledLinkSecret.read(file.path, pairingDirectory: pairing, vaults: { _ in vault }) == secret)
        #expect(try !DistributedInstalledLinkSecret.requirePresent(file.path, pairingDirectory: pairing, vaults: { _ in vault }))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(file.path, in: pairing))
        #expect(ClusterLinkControlAttachment.namesPairingSecret(pairing.appendingPathComponent("edge-0123456789abcdef.secret").path, in: pairing))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(pairing.appendingPathComponent("edge-0123.secret").path, in: pairing))
        #expect(!ClusterLinkControlAttachment.namesPairingSecret(root.appendingPathComponent("other/edge-0123456789abcdef.secret").path, in: pairing),
                "only this install's store names a pairing's secret")
        let missing = root.appendingPathComponent("gone.secret").path
        let refusal = Self.error { try DistributedInstalledValidation.linkSecretMetadata(missing, pairingDirectory: pairing, vaults: { _ in vault }) }
        #expect(refusal != nil && refusal?.contains("unpaired") == false)
    }

    @Test func pairStatusSaysWhereTheKeyIsWithoutIt() {
        let protection = ClusterEdgeSecretItemProtection(accessGroup: "SLDQ2GJ6TL.io.darkbloom.provider",
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, synchronizable: false, binding: "b")
        #expect(ClusterPairCommandLine.linkKeyWords(.keychain(protection, legacyFileLeft: false))
            == "in this Mac's Keychain (this Mac only, readable after its first unlock, not synchronised; access group "
               + "SLDQ2GJ6TL.io.darkbloom.provider); no key file")
        #expect(ClusterPairCommandLine.linkKeyWords(.keychain(protection, legacyFileLeft: true))
            .hasSuffix("an earlier release's key file is still beside it and goes at the next start"))
        #expect(ClusterPairCommandLine.linkKeyWords(.keychainLocked).contains("locked until someone logs in"))
        #expect(ClusterPairCommandLine.linkKeyWords(.missing).contains("pair again"))
        #expect(ClusterPairCommandLine.linkKeyWords(.file).contains("owner-only file"))
    }

    /// An install updated from `old` to `new` by the updater (with `old` kept for rollback), its pairing's key moved into
    /// `vault` (no file), and the updater's recovery store with that vault and `faults`.
    struct Rollback {
        let fixture: UpdateRecoveryFixture
        let mock: MockCoordinator
        let vault: Vault
        let record: ClusterPairingRecord
        let secret: Data
        var keyFile: String { record.link.secretFile }

        static func make(old: String, new: String) async throws -> Rollback {
            let fixture = try UpdateRecoveryFixture(oldVersion: old, newVersion: new)
            let mock = MockCoordinator(release: fixture.mockReleaseFixture(), releaseArtifact: fixture.artifact)
            let outcome = await fixture.updater(baseURL: try await mock.start()).update()
            guard case .updated(_, new) = outcome else { throw InstalledUpdateSetupError.installFailed("\(outcome)") }
            let vault = Vault()
            let store = ClusterPairingStore(directory: ClusterLinkKeyRollback.pairingDirectory(installRoot: fixture.installRoot), vault: vault)
            let (record, _) = try ClusterPairingProviderTests.pair(SoftwareSigner(), SoftwareSigner(),
                                                                   stores: (store, ClusterPairingProviderTests.temporaryStore()))
            let secret = try #require(vault.item(record.peerPin)?.secret)
            return Rollback(fixture: fixture, mock: mock, vault: vault, record: record, secret: secret)
        }

        func store(faults: @escaping @Sendable (UpdateRecoveryStore.FaultPoint) throws -> Void = { _ in }) -> UpdateRecoveryStore {
            UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false, faultInjector: faults,
                                linkKeyVaults: { [vault] _ in vault })
        }

        /// Rolls back under the update lease, as `UpdateSession.rollback` does.
        func rollBack(_ store: UpdateRecoveryStore) throws -> String {
            let lock = try UpdateProcessLock.acquire(at: store.lockPath, operation: "test-rollback")
            defer { lock.release() }
            return try store.rollback(now: 500, reason: "operator rollback")
        }

        func live() throws -> String {
            let binary = try String(contentsOf: fixture.installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"),
                                    encoding: .utf8)
            return String(binary.split(separator: "-").first ?? "")
        }

        func shutdown() async { await mock.shutdown(); fixture.cleanup() }
    }

    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var keyFileBeforeSwap: Bool?
        func set(_ value: Bool) { lock.withLock { if keyFileBeforeSwap == nil { keyFileBeforeSwap = value } } }
    }

    @Test func aRollbackTo0_10_12WritesTheKeyBackBeforeAndAfterTheSwap() async throws {
        let rollback = try await Rollback.make(old: "0.10.12", new: "0.10.13")
        defer { Task { await rollback.shutdown() } }
        #expect(!FileManager.default.fileExists(atPath: rollback.keyFile))
        let seen = Seen()
        let keyFile = rollback.keyFile
        let store = rollback.store(faults: { point in
            switch point {
            case .transactionPersisted:
                // Before the swap: the key is there for 0.10.12 already.
                seen.set(FileManager.default.fileExists(atPath: keyFile))
            case .liveLayoutReplaced:
                // A process of the rolled-back release started between the two writes removes the first one.
                unlink(keyFile)
            default: break
            }
        })
        #expect(try rollback.rollBack(store) == "0.10.12")
        #expect(try rollback.live() == "0.10.12")
        #expect(seen.keyFileBeforeSwap == true, "the key was written back before the swap")
        #expect(FileManager.default.contents(atPath: keyFile) == Self.hexLine(rollback.secret),
                "and written again after it, in 0.10.12's format")
        var info = stat()
        let found = lstat(keyFile, &info) == 0
        #expect(found && info.st_mode & 0o777 == 0o600, "owner-only")
        let fileMode = ClusterPairingStore(directory: URL(fileURLWithPath: keyFile).deletingLastPathComponent())
        #expect(try fileMode.edgeSecret(for: rollback.record) == rollback.secret, "0.10.12's way of reading gets the key")
        #expect(rollback.vault.item(rollback.record.peerPin)?.secret == rollback.secret, "the item stays for the next update")
    }

    @Test func aRollbackToAReleaseThatKeepsKeysInTheKeychainWritesNoFile() async throws {
        let rollback = try await Rollback.make(old: "0.10.13", new: "0.10.14")
        defer { Task { await rollback.shutdown() } }
        #expect(try rollback.rollBack(rollback.store()) == "0.10.13")
        #expect(!FileManager.default.fileExists(atPath: rollback.keyFile), "0.10.13 reads the Keychain: no key file")
        #expect(ClusterLinkKeyRollback.restoresFileRelease("0.10.12"))
        #expect(ClusterLinkKeyRollback.restoresFileRelease("0.10.13-dev.branch.181"), "a DevNet build before 0.10.13")
        #expect(!ClusterLinkKeyRollback.restoresFileRelease("0.10.13"))
        #expect(!ClusterLinkKeyRollback.restoresFileRelease("0.10.14"))
        #expect(ClusterLinkKeyRollback.restoresFileRelease("not a version"), "unreadable: write (harmless)")
    }

    @Test func aRollbacksSecondWriteIsANewFile() async throws {
        let rollback = try await Rollback.make(old: "0.10.12", new: "0.10.13")
        defer { Task { await rollback.shutdown() } }
        let keyFile = rollback.keyFile
        final class Inode: @unchecked Sendable { var value: ino_t = 0 }
        let first = Inode()
        let store = rollback.store(faults: { point in
            guard point == .transactionPersisted else { return }
            var info = stat()
            if lstat(keyFile, &info) == 0 { first.value = info.st_ino }
        })
        #expect(try rollback.rollBack(store) == "0.10.12")
        var after = stat()
        let found = lstat(keyFile, &after) == 0
        #expect(found && first.value != 0 && after.st_ino != first.value,
                "the write after the swap is a new file, newer than every process running then")
        #expect(FileManager.default.contents(atPath: keyFile) == Self.hexLine(rollback.secret))
    }

    /// Each way `recoverInterruptedTransaction` finishes a rollback that died: the staged predecessor installed, the
    /// swap already done, or the predecessor restored from its kept copy (no staging left). Each writes the key back.
    @Test(arguments: ["replays the staging", "finds the swap done", "restores the kept copy"])
    func aRollbackInterruptedIsFinishedWithTheKey(_ path: String) async throws {
        enum ProcessDeath: Error { case injected }
        let rollback = try await Rollback.make(old: "0.10.12", new: "0.10.13")
        defer { Task { await rollback.shutdown() } }
        let keyFile = rollback.keyFile, installRoot = rollback.fixture.installRoot
        let point: UpdateRecoveryStore.FaultPoint = path == "finds the swap done" ? .liveLayoutExchanged : .transactionPersisted
        let dying = rollback.store(faults: { reached in
            guard reached == point else { return }
            unlink(keyFile)   // a process of the rolled-back release removed the first write; then the rollback died
            if path == "restores the kept copy" {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: installRoot.path)) ?? [] where name.hasPrefix(".rollback-staging-") {
                    try? FileManager.default.removeItem(at: installRoot.appendingPathComponent(name))
                }
            }
            throw ProcessDeath.injected
        })
        #expect(throws: ProcessDeath.self) { _ = try rollback.rollBack(dying) }
        #expect(!FileManager.default.fileExists(atPath: keyFile))
        // The next lease holder of the rolled-back release (a watchdog tick) finishes the rollback, and the key with it.
        let next = rollback.store()
        let lock = try UpdateProcessLock.acquire(at: next.lockPath, operation: "next-tick")
        try next.recoverInterruptedTransaction(now: 501)
        lock.release()
        #expect(try rollback.live() == "0.10.12", "\(path)")
        #expect(FileManager.default.contents(atPath: keyFile) == Self.hexLine(rollback.secret), "\(path): recovery wrote the key back")
    }
}

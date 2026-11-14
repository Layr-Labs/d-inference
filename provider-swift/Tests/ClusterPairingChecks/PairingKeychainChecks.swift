import Darwin
import Foundation
import Security
@testable import DarkbloomClusterSecurity

/// The edge secret in the data-protection Keychain: a new pairing writes no file, 0.10.12's file moves into the
/// Keychain on first use (and is overwritten, then removed), every step of that move survives a crash or a second
/// process, a locked Keychain refuses without touching anything, and a rollback to 0.10.12 gets its files back.
/// `MemoryVault` stands in for the Keychain; `KeychainRecorder` checks the real vault's queries; `keychainReal` runs
/// against this Mac's Keychain where the build is entitled (it is skipped, and says so, where it is not).
extension PairingCheck {
    /// The Keychain as the store sees it, in memory, with the failures a real one has.
    final class MemoryVault: ClusterEdgeSecretVault, @unchecked Sendable {
        enum Mode { case normal, locked, notEntitled }
        private let lock = NSLock()
        private var items: [String: ClusterEdgeSecretItem] = [:]
        private var _mode = Mode.normal
        private var _failReads = 0
        private(set) var adds = 0, replaces = 0, deletes = 0
        /// Runs after an item was stored (inside the vault's lock).
        var afterStore: ((MemoryVault) -> Void)?
        private var reads = 0
        private var readHook: (number: Int, body: () -> Void)?
        /// Runs `body` right after the `number`-th read from now has answered: another process acting at that moment.
        func onRead(_ number: Int, _ body: @escaping () -> Void) { lock.withLock { reads = 0; readHook = (number, body) } }

        var mode: Mode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
        /// The next `count` reads fail with a transient status.
        func failReads(_ count: Int) { lock.withLock { _failReads = count } }
        func item(_ pin: String) -> ClusterEdgeSecretItem? { lock.withLock { items[pin] } }
        func put(_ pin: String, _ item: ClusterEdgeSecretItem?) { lock.withLock { items[pin] = item } }
        var count: Int { lock.withLock { items.count } }

        private func refusal() -> ClusterEdgeSecretVaultFailure? {
            switch _mode { case .normal: return nil; case .locked: return .locked; case .notEntitled: return .notEntitled }
        }

        func read(peerPin: String) -> ClusterEdgeSecretVaultRead {
            let (answer, hook) = lock.withLock { () -> (ClusterEdgeSecretVaultRead, (() -> Void)?) in
                reads += 1
                var hook: (() -> Void)?
                if let pending = readHook, pending.number == reads { hook = pending.body; readHook = nil }
                if let refusal = refusal() { return (.failed(refusal), hook) }
                if _failReads > 0 { _failReads -= 1; return (.failed(.status(errSecIO)), hook) }
                return (items[peerPin].map(ClusterEdgeSecretVaultRead.found) ?? .absent, hook)
            }
            hook?()
            return answer
        }

        func add(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if let refusal = refusal() { return .failed(refusal) }
                guard items[peerPin] == nil else { return .exists }
                items[peerPin] = item; adds += 1
                afterStore?(self)
                return .done
            }
        }

        func replace(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if let refusal = refusal() { return .failed(refusal) }
                guard items[peerPin] != nil else { return .absent }
                items[peerPin] = item; replaces += 1
                afterStore?(self)
                return .done
            }
        }

        func delete(peerPin: String) -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if let refusal = refusal() { return .failed(refusal) }
                items[peerPin] = nil; deletes += 1
                return .done
            }
        }

        func deleteAll() -> ClusterEdgeSecretVaultWrite {
            lock.withLock {
                if let refusal = refusal() { return .failed(refusal) }
                items = [:]; deletes += 1
                return .done
            }
        }

        func protection(peerPin: String) -> Result<ClusterEdgeSecretItemProtection?, ClusterEdgeSecretVaultFailure> {
            lock.withLock {
                if let refusal = refusal() { return .failure(refusal) }
                return .success(items[peerPin].map {
                    ClusterEdgeSecretItemProtection(accessGroup: "TEST.group", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                                                    synchronizable: false, binding: $0.binding)
                })
            }
        }

        /// As `afterStore` would leave it, from outside a call (tests that change the vault between calls).
        func failReadsUnlocked(_ count: Int) { _failReads = count }
    }

    /// `SecItem` with the semantics the vault relies on (one item per service + account, duplicates refused), recording
    /// every query, or answering every call with one status.
    final class KeychainRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: [String: Any]] = [:]
        private(set) var adds: [[String: Any]] = [], copies: [[String: Any]] = [], updates: [([String: Any], [String: Any])] = []
        private(set) var deletes: [[String: Any]] = []
        var status: OSStatus?
        /// Whether the process holds a keychain access group (a signed build).
        var holds = false
        /// Stores an item as a broken writer would: without its binding.
        func storeWithoutBinding(service: String, account: String, data: Data) {
            lock.withLock { stored["\(service)/\(account)"] = [kSecValueData as String: data] }
        }

        private static func key(_ query: [String: Any]) -> String {
            "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
        }

        var calls: ClusterKeychainCalls {
            ClusterKeychainCalls(
                copyMatching: { query in
                    self.lock.withLock {
                        self.copies.append(query)
                        if let status = self.status { return (status, nil) }
                        guard let item = self.stored[Self.key(query)] else { return (errSecItemNotFound, nil) }
                        var answer = item
                        if query[kSecReturnData as String] as? Bool != true { answer[kSecValueData as String] = nil }
                        answer[kSecAttrSynchronizable as String] = false
                        return (errSecSuccess, answer)
                    }
                },
                add: { attributes in
                    self.lock.withLock {
                        self.adds.append(attributes)
                        if let status = self.status { return status }
                        guard self.stored[Self.key(attributes)] == nil else { return errSecDuplicateItem }
                        self.stored[Self.key(attributes)] = attributes
                        return errSecSuccess
                    }
                },
                update: { query, changes in
                    self.lock.withLock {
                        self.updates.append((query, changes))
                        if let status = self.status { return status }
                        guard var item = self.stored[Self.key(query)] else { return errSecItemNotFound }
                        for (key, value) in changes { item[key] = value }
                        self.stored[Self.key(query)] = item
                        return errSecSuccess
                    }
                },
                delete: { query in
                    self.lock.withLock {
                        self.deletes.append(query)
                        if let status = self.status { return status }
                        guard query[kSecAttrAccount as String] != nil else {
                            let service = "\(query[kSecAttrService as String] as? String ?? "")/"
                            let matching = self.stored.keys.filter { $0.hasPrefix(service) }
                            matching.forEach { self.stored[$0] = nil }
                            return matching.isEmpty ? errSecItemNotFound : errSecSuccess
                        }
                        return self.stored.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
                    }
                },
                holdsKeychainAccessGroups: { self.lock.withLock { self.holds } })
        }
    }

    // MARK: - Helpers

    static func hexLine(_ secret: Data) -> Data { Data((secret.map { String(format: "%02x", $0) }.joined() + "\n").utf8) }

    /// Every `edge-*.secret` file in the store's folder.
    static func secretFiles(_ store: ClusterPairingStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [])
            .filter { $0.hasPrefix("edge-") && $0.hasSuffix(".secret") }
    }

    static func contents(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    /// Makes `url` look written by an earlier process (an hour before this one started), as 0.10.12's file and a crash's
    /// leftovers are on a real Mac.
    static func backdate(_ url: URL) {
        let earlier = ClusterPairingStore.processStart - 3600
        var times = [timeval(tv_sec: Int(earlier), tv_usec: 0), timeval(tv_sec: Int(earlier), tv_usec: 0)]
        _ = utimes(url.path, &times)
    }

    /// A pairing stored by 0.10.12's code path (no vault: its owner-only file), and the same folder opened by this build.
    static func legacyPairing(_ name: String, vault: MemoryVault)
        -> (legacy: ClusterPairingStore, store: ClusterPairingStore, outcome: ClusterPairingOutcome, record: ClusterPairingRecord)? {
        let directory = freshDirectory(name).appendingPathComponent("cluster-pairing")
        let legacy = ClusterPairingStore(directory: directory)
        let (outcome, _) = pairedOutcomes()
        guard (try? legacy.commit(outcome, edgeID: UUID())) != nil,
              let record = (try? legacy.load())?.pairing(peerPin: outcome.peer.pin) else { expect(false, "\(name): legacy commit"); return nil }
        expectEqual(contents(legacy.secretFile(peerPin: outcome.peer.pin)), hexLine(outcome.edgeSecret), "\(name): 0.10.12 wrote its file")
        backdate(legacy.secretFile(peerPin: outcome.peer.pin))
        return (legacy, ClusterPairingStore(directory: directory, vault: vault), outcome, record)
    }

    static func storeError(_ body: () throws -> Any) -> ClusterPairingStoreError? {
        do { _ = try body(); return nil } catch let error as ClusterPairingStoreError { return error } catch { return nil }
    }

    // MARK: - Checks

    static func keychainFreshPairing() {
        let vault = MemoryVault()
        let store = ClusterPairingStore(directory: freshDirectory("kc-fresh").appendingPathComponent("cluster-pairing"), vault: vault)
        let (outcome, _) = pairedOutcomes()
        guard (try? store.commit(outcome, edgeID: UUID())) != nil,
              let records = try? store.load(), let record = records.pairing(peerPin: outcome.peer.pin) else {
            expect(false, "commit with the Keychain"); return
        }
        expectEqual(secretFiles(store), [], "a fresh pairing writes no secret file")
        expectEqual(vault.item(outcome.peer.pin), ClusterEdgeSecretItem(secret: outcome.edgeSecret, binding: ClusterPairingStore.binding(of: record)),
                    "the secret is the Keychain item of the other Mac's pin, bound to this pairing")
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "it reads back")
        expect(record.link.secretFile.hasPrefix("/") && record.link.secretFile == store.secretFile(peerPin: outcome.peer.pin).path,
               "pairings.json keeps 0.10.12's secretFile path (a rollback still reads the store)")
        let recordsText = String(decoding: contents(store.recordsFile) ?? Data(), as: UTF8.self)
        let auditText = String(decoding: contents(store.auditFile) ?? Data(), as: UTF8.self)
        let secretHex = outcome.edgeSecret.map { String(format: "%02x", $0) }.joined()
        expect(!recordsText.contains(secretHex) && !auditText.contains(secretHex), "the secret is in neither pairings.json nor the audit")
        expectEqual(mode(store.recordsFile.path), 0o600, "pairings.json is still 0600")
    }

    static func keychainMigration() {
        let vault = MemoryVault()
        guard case let (legacy, store, outcome, record)? = legacyPairing("kc-migrate", vault: vault) else { return }
        let file = store.secretFile(peerPin: outcome.peer.pin)
        // A second name for the same file shows it was overwritten before it was removed.
        let witness = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("witness")
        expect(link(file.path, witness.path) == 0, "(setup) a hard link to the legacy file")
        expectEqual(store.linkKeyLocation(for: record), .file, "before the first read, the key is 0.10.12's file")
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "the first read returns 0.10.12's secret")
        guard case .keychain(let protection, legacyFileLeft: false) = store.linkKeyLocation(for: record) else {
            expect(false, "after the move the key is in the Keychain, with no file"); return
        }
        expect(protection.afterFirstUnlockThisDeviceOnly, "as the Keychain reports it")
        expectEqual(secretFiles(store), [], "after migration no secret file remains")
        expectEqual(vault.item(outcome.peer.pin)?.secret, outcome.edgeSecret, "the secret is in the Keychain")
        expectEqual(vault.item(outcome.peer.pin)?.binding, ClusterPairingStore.binding(of: record), "bound to this pairing")
        let witnessed = contents(witness) ?? Data([1])
        expect(!witnessed.isEmpty && witnessed.allSatisfy { $0 == 0 }, "the file was overwritten before it was unlinked")
        unlink(witness.path)
        let writes = (vault.adds, vault.replaces)
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "a second read returns the same secret")
        expect(vault.adds == writes.0 && vault.replaces == writes.1, "the migration is idempotent: a second read writes nothing")
        expectEqual(storeError { try legacy.edgeSecret(for: record) }, .linkKeyMissing,
                    "0.10.12's way of reading (the file) finds nothing now")
        let audit = String(decoding: contents(store.auditFile) ?? Data(), as: UTF8.self)
        expect(audit.contains("\"event\":\"link_key_moved_to_keychain\""), "the audit names the move")
        expect(!audit.contains(outcome.edgeSecret.map { String(format: "%02x", $0) }.joined()), "and never the secret")
    }

    static func keychainCrashMidMigration() {
        // Each state a crash can leave, then the next run.
        for (name, prepare) in [
            ("stored, file still there", { (vault: MemoryVault, pin: String, item: ClusterEdgeSecretItem, file: URL) in vault.put(pin, item) }),
            ("stored, file half overwritten", { (vault: MemoryVault, pin: String, item: ClusterEdgeSecretItem, file: URL) in
                vault.put(pin, item)
                let fd = open(file.path, O_WRONLY | O_NOFOLLOW); _ = Data(count: 20).withUnsafeBytes { pwrite(fd, $0.baseAddress, 20, 0) }; close(fd)
            }),
            ("stored, file overwritten", { (vault: MemoryVault, pin: String, item: ClusterEdgeSecretItem, file: URL) in
                vault.put(pin, item)
                let fd = open(file.path, O_WRONLY | O_NOFOLLOW); _ = Data(count: 65).withUnsafeBytes { pwrite(fd, $0.baseAddress, 65, 0) }; close(fd)
            }),
            ("nothing done yet", { (_: MemoryVault, _: String, _: ClusterEdgeSecretItem, _: URL) in }),
        ] as [(String, (MemoryVault, String, ClusterEdgeSecretItem, URL) -> Void)] {
            let vault = MemoryVault()
            guard case let (_, store, outcome, record)? = legacyPairing("kc-crash", vault: vault) else { continue }
            let item = ClusterEdgeSecretItem(secret: outcome.edgeSecret, binding: ClusterPairingStore.binding(of: record))
            prepare(vault, outcome.peer.pin, item, store.secretFile(peerPin: outcome.peer.pin))
            backdate(store.secretFile(peerPin: outcome.peer.pin))
            expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "\(name): the next run reads the secret")
            expectEqual(secretFiles(store), [], "\(name): and no secret file remains")
            expectEqual(vault.item(outcome.peer.pin), item, "\(name): the Keychain item is the pairing's")
        }
        // The read-back fails once (the Keychain hiccups after the store): nothing is removed, the next read finishes.
        let vault = MemoryVault()
        guard case let (_, store, outcome, record)? = legacyPairing("kc-readback", vault: vault) else { return }
        vault.afterStore = { $0.failReadsUnlocked(1) }
        expectEqual(storeError { try store.edgeSecret(for: record) }, .keychainUnavailable(errSecIO),
                    "a read-back that fails is an error, not a guess")
        expectEqual(contents(store.secretFile(peerPin: outcome.peer.pin)), hexLine(outcome.edgeSecret), "and the file is kept")
        vault.afterStore = nil
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "the next read finishes the move")
        expectEqual(secretFiles(store), [], "and removes the file")
    }

    static func keychainTwoProcesses() {
        let vault = MemoryVault()
        guard case let (_, first, outcome, record)? = legacyPairing("kc-race", vault: vault) else { return }
        // Two stores on one folder take two locks, as two processes do; they share only the Keychain and the files.
        let second = ClusterPairingStore(directory: first.directory, vault: vault)
        final class Reads: @unchecked Sendable { let lock = NSLock(); var values = [Data?]() }
        let reads = Reads()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let value = try? (index % 2 == 0 ? first : second).edgeSecret(for: record)
            reads.lock.withLock { reads.values.append(value) }
        }
        let read = reads.values
        expect(read.count == 32 && read.allSatisfy { $0 == outcome.edgeSecret }, "every read in both processes returns the secret")
        expectEqual(vault.adds, 1, "one item was added")
        expectEqual(vault.item(outcome.peer.pin)?.secret, outcome.edgeSecret, "the Keychain holds the secret")
        expectEqual(secretFiles(first), [], "no secret file remains")
    }

    static func keychainMissingOrCorrupt() {
        // Neither the Keychain nor a file: the pairing's key is gone (a reset Keychain, a copied store).
        let vault = MemoryVault()
        let store = ClusterPairingStore(directory: freshDirectory("kc-missing").appendingPathComponent("cluster-pairing"), vault: vault)
        let (outcome, _) = pairedOutcomes()
        guard (try? store.commit(outcome, edgeID: UUID())) != nil, let record = (try? store.load())?.pairing(peerPin: outcome.peer.pin)
        else { expect(false, "commit"); return }
        vault.put(outcome.peer.pin, nil)
        expectEqual(storeError { try store.edgeSecret(for: record) }, .linkKeyMissing, "no item and no file: the key is missing")
        expectEqual(store.linkKeyLocation(for: record), .missing, "and its location says so")
        // A corrupt or unsafe legacy file is refused, kept as it is, and never moved into the Keychain.
        for (name, bytes, permissions) in [("not hex", Data("not-a-secret\n".utf8), mode_t(0o600)),
                                           ("31 bytes", hexLine(Data(repeating: 7, count: 31)), mode_t(0o600)),
                                           ("upper case", Data((String(repeating: "AB", count: 32) + "\n").utf8), mode_t(0o600)),
                                           ("group-readable", hexLine(Data(repeating: 9, count: 32)), mode_t(0o644))] {
            let vault = MemoryVault()
            guard case let (_, store, outcome, record)? = legacyPairing("kc-corrupt", vault: vault) else { continue }
            let file = store.secretFile(peerPin: outcome.peer.pin)
            FileManager.default.createFile(atPath: file.path, contents: bytes)
            chmod(file.path, permissions)
            let error = storeError { try store.edgeSecret(for: record) }
            expect(error == .malformed(file.lastPathComponent) || error == .unsafe(file.lastPathComponent),
                   "\(name): refused (got \(String(describing: error)))")
            expectEqual(contents(file), bytes, "\(name): the file is kept as it was")
            expectEqual(vault.count, 0, "\(name): nothing went into the Keychain")
        }
        // A link in place of the file is refused, not followed.
        let linked = MemoryVault()
        guard case let (_, linkedStore, linkedOutcome, linkedRecord)? = legacyPairing("kc-symlink", vault: linked) else { return }
        let file = linkedStore.secretFile(peerPin: linkedOutcome.peer.pin)
        let moved = file.path + ".real"
        rename(file.path, moved); symlink(moved, file.path)
        expectEqual(storeError { try linkedStore.edgeSecret(for: linkedRecord) }, .unsafe(file.lastPathComponent), "a symbolic link is refused")
        expectEqual(linked.count, 0, "and nothing went into the Keychain")
    }

    static func keychainLocked() {
        let vault = MemoryVault()
        guard case let (_, store, outcome, record)? = legacyPairing("kc-locked", vault: vault) else { return }
        let file = store.secretFile(peerPin: outcome.peer.pin)
        vault.mode = .locked
        let error = storeError { try store.edgeSecret(for: record) }
        expectEqual(error, .keychainLocked, "a locked Keychain refuses (fail closed), even with 0.10.12's file there")
        expect(String(describing: error ?? .notPaired).contains("locked") && String(describing: error ?? .notPaired).contains("logs in"),
               "and says why: locked until someone logs in")
        expectEqual(contents(file), hexLine(outcome.edgeSecret), "the file is not touched")
        expectEqual(vault.count, 0, "nothing was stored")
        expectEqual(store.linkKeyLocation(for: record), .keychainLocked, "the location says locked")
        let (other, _) = pairedOutcomes()
        expectEqual(storeError { try store.commit(other, edgeID: UUID()) }, .keychainLocked, "pairing while locked is refused")
        expectEqual((try? store.load())?.pairings.count, 1, "and changes no record")
        expectEqual(storeError { try store.forget(peerPin: outcome.peer.pin) }, .keychainLocked, "unpairing while locked is refused")
        expectEqual((try? store.load())?.pairing(peerPin: outcome.peer.pin) != nil, true, "and keeps the pairing")
        vault.mode = .normal
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "after the login it reads, and moves the file")
        expectEqual(secretFiles(store), [], "no secret file remains")
        vault.mode = .locked
        expectEqual(storeError { try store.edgeSecret(for: record) }, .keychainLocked, "locked again (a restart): refused again")
        vault.mode = .normal
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "and back after the next login")
    }

    static func keychainRollback() {
        // After the move, the rollback path writes 0.10.12's file back; 0.10.12's code path reads it.
        let vault = MemoryVault()
        guard case let (legacy, store, outcome, record)? = legacyPairing("kc-rollback", vault: vault) else { return }
        let file = store.secretFile(peerPin: outcome.peer.pin)
        _ = try? store.edgeSecret(for: record)
        expectEqual(secretFiles(store), [], "(setup) moved")
        let lines = store.writeLegacyFilesForRollback()
        expectEqual(contents(file), hexLine(outcome.edgeSecret), "the rollback path writes 0.10.12's file back, byte for byte")
        expectEqual(mode(file.path), 0o600, "owner-only")
        expect(lines.count == 1 && !lines.joined().contains(outcome.edgeSecret.map { String(format: "%02x", $0) }.joined()),
               "one line per pairing, without the secret")
        expectEqual(try? legacy.edgeSecret(for: record), outcome.edgeSecret, "0.10.12's way of reading gets the same secret")
        expectEqual(vault.item(outcome.peer.pin)?.secret, outcome.edgeSecret, "the item stays")
        // The release being rolled back still runs (its cluster service drives the rollback) and keeps reading.
        if case .keychain(_, legacyFileLeft: true) = store.linkKeyLocation(for: record) {} else {
            expect(false, "--status says a key file is beside the item after the write-back")
        }
        let second = ClusterPairingStore(directory: store.directory, vault: vault)
        expectEqual(try? second.edgeSecret(for: record), outcome.edgeSecret, "a process started before the write-back reads the item")
        expectEqual(contents(file), hexLine(outcome.edgeSecret), "and leaves the written-back file for the release the rollback restores")
        backdate(file)
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "forward again, a later process reads the item")
        expectEqual(secretFiles(store), [], "and removes the file again")
        // 0.10.12 paired the same Macs again after the rollback: the newer pairing's file wins over the older item.
        let identities = (SoftwareIdentity(), SoftwareIdentity())
        let runs = (1...2).map { _ in runInMemory(TestPairing.participant(identities.0, interface: "en7"),
                                                  TestPairing.participant(identities.1, interface: "en6")) }
        guard let older = runs[0].outcomes[.listener], let newer = runs[1].outcomes[.listener] else { expect(false, "two ceremonies"); return }
        let directory = freshDirectory("kc-repair").appendingPathComponent("cluster-pairing")
        let fileMode = ClusterPairingStore(directory: directory), keychain = ClusterPairingStore(directory: directory, vault: vault)
        _ = try? keychain.commit(older, edgeID: UUID())
        _ = keychain.writeLegacyFilesForRollback()
        _ = try? fileMode.commit(newer, edgeID: UUID())
        guard let current = (try? keychain.load())?.pairing(peerPin: newer.peer.pin) else { expect(false, "re-paired record"); return }
        expectEqual(try? keychain.edgeSecret(for: current), newer.edgeSecret, "a pairing 0.10.12 made after the rollback wins")
        expectEqual(vault.item(newer.peer.pin), ClusterEdgeSecretItem(secret: newer.edgeSecret, binding: ClusterPairingStore.binding(of: current)),
                    "it replaces the older item")
        expectEqual(secretFiles(keychain), [], "and its file is removed")
        // A locked Keychain during the rollback writes nothing (0.10.12 then says to pair again).
        let lockedVault = MemoryVault()
        guard case let (_, lockedStore, _, lockedRecord)? = legacyPairing("kc-rollback-locked", vault: lockedVault) else { return }
        _ = try? lockedStore.edgeSecret(for: lockedRecord)
        lockedVault.mode = .locked
        let lockedLines = lockedStore.writeLegacyFilesForRollback()
        expectEqual(secretFiles(lockedStore), [], "a locked Keychain writes no file back")
        expect(lockedLines.count == 1 && lockedLines[0].contains("locked"), "and says so")
    }

    static func keychainUnpairAndCeremonyRollback() {
        let vault = MemoryVault()
        let store = ClusterPairingStore(directory: freshDirectory("kc-unpair").appendingPathComponent("cluster-pairing"), vault: vault)
        let (first, _) = pairedOutcomes()
        _ = try? store.commit(first, edgeID: UUID())
        guard let firstRecord = (try? store.load())?.pairing(peerPin: first.peer.pin) else { expect(false, "commit"); return }
        let firstItem = vault.item(first.peer.pin)
        // The other Mac did not finish a second ceremony: the earlier item comes back exactly.
        if let token = try? store.commit(first, edgeID: UUID()) { store.rollback(token) }
        expectEqual(vault.item(first.peer.pin), firstItem, "the ceremony's rollback restores the earlier item")
        expectEqual((try? store.load())?.pairing(peerPin: first.peer.pin), firstRecord, "and the earlier record")
        expectEqual(secretFiles(store), [], "and writes no file")
        // Unpairing deletes the item.
        expectEqual((try? store.forget(peerPin: first.peer.pin))?.peerPin, first.peer.pin, "unpair")
        expectEqual(vault.item(first.peer.pin), nil, "unpairing deletes the Keychain item")
        expectEqual(secretFiles(store), [], "and leaves no file")
        // Rolling back a first pairing leaves nothing.
        let (second, _) = pairedOutcomes()
        if let token = try? store.commit(second, edgeID: UUID()) { store.rollback(token) }
        expectEqual(vault.item(second.peer.pin), nil, "a rolled back first pairing leaves no item")
        expectEqual(secretFiles(store), [], "and no file")
        // A new pairing over 0.10.12's file removes it; its rollback puts the file back as it was.
        let legacyVault = MemoryVault()
        guard case let (_, legacyStore, legacyOutcome, _)? = legacyPairing("kc-over-legacy", vault: legacyVault) else { return }
        let file = legacyStore.secretFile(peerPin: legacyOutcome.peer.pin)
        let token = try? legacyStore.commit(legacyOutcome, edgeID: UUID())
        expectEqual(secretFiles(legacyStore), [], "a new pairing over 0.10.12's file removes it")
        if let token { legacyStore.rollback(token) }
        expectEqual(contents(file), hexLine(legacyOutcome.edgeSecret), "its rollback restores 0.10.12's file byte for byte")
        expectEqual(legacyVault.item(legacyOutcome.peer.pin), nil, "and leaves no item")
    }

    static func keychainNotEntitled() {
        let vault = MemoryVault()
        vault.mode = .notEntitled
        let store = ClusterPairingStore(directory: freshDirectory("kc-unentitled").appendingPathComponent("cluster-pairing"), vault: vault)
        let (outcome, _) = pairedOutcomes()
        guard (try? store.commit(outcome, edgeID: UUID())) != nil, let record = (try? store.load())?.pairing(peerPin: outcome.peer.pin)
        else { expect(false, "commit without the entitlement"); return }
        expectEqual(contents(store.secretFile(peerPin: outcome.peer.pin)), hexLine(outcome.edgeSecret),
                    "a build without the Keychain entitlement keeps 0.10.12's file")
        expectEqual(mode(store.secretFile(peerPin: outcome.peer.pin).path), 0o600, "owner-only")
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "and reads it")
        expectEqual(vault.adds, 0, "nothing went into the Keychain")
    }

    static func keychainItemAttributes() {
        let recorder = KeychainRecorder()
        let vault = ClusterKeychainEdgeSecretVault(service: "io.example.cluster-pairing.edge-secret", accessGroup: "TEAM.io.example",
                                                   calls: recorder.calls)
        let store = ClusterPairingStore(directory: freshDirectory("kc-attributes").appendingPathComponent("cluster-pairing"), vault: vault)
        let (outcome, _) = pairedOutcomes()
        _ = try? store.commit(outcome, edgeID: UUID())
        guard let record = (try? store.load())?.pairing(peerPin: outcome.peer.pin), let added = recorder.adds.last else {
            expect(false, "a pairing adds a Keychain item"); return
        }
        expectEqual(added[kSecClass as String] as? String, kSecClassGenericPassword as String, "a generic password")
        expectEqual(added[kSecUseDataProtectionKeychain as String] as? Bool, true, "in the data-protection Keychain")
        expectEqual(added[kSecAttrAccessGroup as String] as? String, "TEAM.io.example", "in the app's access group")
        expectEqual(added[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                    "after first unlock, this device only")
        expectEqual(added[kSecAttrSynchronizable as String] as? Bool, false, "never synchronised (no iCloud)")
        expectEqual(added[kSecAttrService as String] as? String, "io.example.cluster-pairing.edge-secret", "under the install's service")
        expectEqual(added[kSecAttrAccount as String] as? String, outcome.peer.pin, "keyed by the other Mac's pin")
        expectEqual(added[kSecValueData as String] as? Data, outcome.edgeSecret, "holding the 32 secret bytes")
        expectEqual((added[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }, ClusterPairingStore.binding(of: record),
                    "bound to the pairing")
        expect(added[kSecAttrAccessControl as String] == nil, "no user-presence control: a background service reads it")
        _ = try? store.edgeSecret(for: record)
        for query in recorder.copies + recorder.deletes + recorder.updates.map({ $0.0 }) {
            expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true && query[kSecAttrAccessGroup as String] as? String == "TEAM.io.example"
                   && query[kSecAttrSynchronizable as String] as? Bool == false, "every call names the data-protection Keychain and the group")
        }
        let read = recorder.copies.first { $0[kSecReturnData as String] as? Bool == true }
        expect(read?[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String, "a read asks for one item")
        _ = try? store.forget(peerPin: outcome.peer.pin)
        expectEqual(recorder.deletes.last?[kSecAttrAccount as String] as? String, outcome.peer.pin, "unpairing deletes that item")
        // Each Keychain status the store can meet.
        for (status, expected) in [(errSecInteractionNotAllowed, ClusterPairingStoreError.keychainLocked),
                                   (OSStatus(-25291), ClusterPairingStoreError.keychainUnavailable(-25291))] {
            let failing = KeychainRecorder()
            let store = ClusterPairingStore(directory: freshDirectory("kc-status").appendingPathComponent("cluster-pairing"),
                vault: ClusterKeychainEdgeSecretVault(service: "s", accessGroup: "g", calls: failing.calls))
            let (outcome, _) = pairedOutcomes()
            _ = try? ClusterPairingStore(directory: store.directory).commit(outcome, edgeID: UUID())
            guard let record = (try? store.load())?.pairing(peerPin: outcome.peer.pin) else { expect(false, "legacy pairing"); continue }
            failing.status = status
            expectEqual(storeError { try store.edgeSecret(for: record) }, expected, "OSStatus \(status)")
        }
        let unentitled = KeychainRecorder()
        unentitled.status = errSecMissingEntitlement
        let fileStore = ClusterPairingStore(directory: freshDirectory("kc-34018").appendingPathComponent("cluster-pairing"),
            vault: ClusterKeychainEdgeSecretVault(service: "s", accessGroup: "g", calls: unentitled.calls))
        let (plain, _) = pairedOutcomes()
        _ = try? fileStore.commit(plain, edgeID: UUID())
        expectEqual(contents(fileStore.secretFile(peerPin: plain.peer.pin)), hexLine(plain.edgeSecret),
                    "errSecMissingEntitlement (ad-hoc build): 0.10.12's file")
    }

    static func keychainNothingPrinted() {
        let secret = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let item = ClusterEdgeSecretItem(secret: secret, binding: "link-epoch e edge d")
        let vault = ClusterKeychainEdgeSecretVault(service: "s", accessGroup: "g")
        var dumped = ""
        dump(item, to: &dumped)
        for text in [String(describing: item), String(reflecting: item), "\(vault)", String(describing: ClusterEdgeSecretVaultRead.found(item)), dumped]
            + [ClusterPairingStoreError.keychainLocked, .keychainUnavailable(-1), .linkKeyMissing].map(String.init(describing:)) {
            expect(!text.contains(hex), "no secret in \"\(text.prefix(60))\"")
        }
    }

    /// Two orders of two processes the lock-free reads must survive, and a pairing replaced under a stale reader.
    static func keychainInterleavings() {
        // P1 reads the Keychain under the lock (nothing yet); a writer that took no lock then stores the item and removes
        // the file; P1 finds no file and reads the Keychain again.
        let vault = MemoryVault()
        guard case let (_, store, outcome, record)? = legacyPairing("kc-interleave", vault: vault) else { return }
        let file = store.secretFile(peerPin: outcome.peer.pin)
        vault.onRead(2) {
            vault.put(outcome.peer.pin, ClusterEdgeSecretItem(secret: outcome.edgeSecret, binding: ClusterPairingStore.binding(of: record)))
            unlink(file.path)
        }
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret,
                    "a process whose file another process just moved reads the item, never \"gone\"")
        expectEqual(secretFiles(store), [], "and no file is left")
        // A reader holding the previous pairing while a new ceremony replaced it: nothing of the new pairing is touched.
        let identities = (SoftwareIdentity(), SoftwareIdentity())
        let runs = (1...2).map { _ in runInMemory(TestPairing.participant(identities.0, interface: "en7"),
                                                  TestPairing.participant(identities.1, interface: "en6")) }
        guard let older = runs[0].outcomes[.listener], let newer = runs[1].outcomes[.listener] else { expect(false, "two ceremonies"); return }
        let directory = freshDirectory("kc-stale-reader").appendingPathComponent("cluster-pairing")
        let fileMode = ClusterPairingStore(directory: directory), keychain = ClusterPairingStore(directory: directory, vault: vault)
        _ = try? fileMode.commit(older, edgeID: UUID())
        guard let olderRecord = (try? fileMode.load())?.pairing(peerPin: older.peer.pin) else { expect(false, "older record"); return }
        backdate(fileMode.secretFile(peerPin: older.peer.pin))
        _ = try? keychain.commit(newer, edgeID: UUID())
        let newItem = vault.item(newer.peer.pin)
        // The earlier pairing's file is back (an earlier release's process wrote it), next to the new pairing's item.
        let olderFile = keychain.secretFile(peerPin: older.peer.pin)
        FileManager.default.createFile(atPath: olderFile.path, contents: hexLine(older.edgeSecret), attributes: [.posixPermissions: 0o600])
        backdate(olderFile)
        expectEqual(storeError { try keychain.edgeSecret(for: olderRecord) }, .pairingChanged, "a reader holding the earlier pairing is refused")
        expectEqual(vault.item(newer.peer.pin), newItem, "and the new pairing's item is untouched")
    }

    /// A signed build that gets errSecMissingEntitlement (a group it lacks) fails closed and writes no file.
    static func keychainSignedBuildNeverFallsBack() {
        let recorder = KeychainRecorder()
        recorder.status = errSecMissingEntitlement
        recorder.holds = true
        let store = ClusterPairingStore(directory: freshDirectory("kc-signed-34018").appendingPathComponent("cluster-pairing"),
            vault: ClusterKeychainEdgeSecretVault(service: "s", accessGroup: "TEAM.other", calls: recorder.calls))
        let (outcome, _) = pairedOutcomes()
        expectEqual(storeError { try store.commit(outcome, edgeID: UUID()) }, .keychainUnavailable(errSecMissingEntitlement),
                    "a pairing is refused, as the status it is")
        expectEqual(secretFiles(store), [], "and no secret file is written")
        let legacy = MemoryVault()
        guard case let (_, _, legacyOutcome, legacyRecord)? = legacyPairing("kc-signed-read", vault: legacy) else { return }
        let reader = ClusterPairingStore(directory: URL(fileURLWithPath: legacyRecord.link.secretFile).deletingLastPathComponent(),
            vault: ClusterKeychainEdgeSecretVault(service: "s", accessGroup: "TEAM.other", calls: recorder.calls))
        expectEqual(storeError { try reader.edgeSecret(for: legacyRecord) }, .keychainUnavailable(errSecMissingEntitlement),
                    "a read fails closed instead of taking the file")
        expectEqual(contents(reader.secretFile(peerPin: legacyOutcome.peer.pin)), hexLine(legacyOutcome.edgeSecret), "which is kept")
    }

    /// An item without its binding (a broken writer) is an earlier pairing's: a pairing replaces it, unpairing deletes it,
    /// and the last unpairing sweeps every item of the store.
    static func keychainBrokenAndOrphanItems() {
        let recorder = KeychainRecorder()
        let vault = ClusterKeychainEdgeSecretVault(service: "io.example.edge", accessGroup: "TEAM.io.example", calls: recorder.calls)
        let store = ClusterPairingStore(directory: freshDirectory("kc-broken").appendingPathComponent("cluster-pairing"), vault: vault)
        let (outcome, _) = pairedOutcomes()
        recorder.storeWithoutBinding(service: "io.example.edge", account: outcome.peer.pin, data: Data(repeating: 1, count: 32))
        recorder.storeWithoutBinding(service: "io.example.edge", account: String(repeating: "c", count: 64), data: Data(repeating: 2, count: 32))
        expect((try? store.commit(outcome, edgeID: UUID())) != nil, "a pairing replaces an item without a binding")
        guard let record = (try? store.load())?.pairing(peerPin: outcome.peer.pin) else { expect(false, "record"); return }
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "and reads its own")
        expect((try? store.forget(peerPin: outcome.peer.pin)) != nil, "unpairing works")
        expectEqual(vault.read(peerPin: outcome.peer.pin), .absent, "and deletes its item")
        expectEqual(vault.read(peerPin: String(repeating: "c", count: 64)), .absent,
                    "the last unpairing sweeps the store's orphan items too")
        expect(recorder.deletes.contains { $0[kSecAttrAccount as String] == nil && $0[kSecAttrService as String] as? String == "io.example.edge" },
               "through one delete of the store's service")
    }

    /// The rollback's second write (`rewrite`) makes a new file, so a process started between the two writes leaves it.
    static func keychainRollbackRewrite() {
        let vault = MemoryVault()
        guard case let (_, store, outcome, record)? = legacyPairing("kc-rewrite", vault: vault) else { return }
        _ = try? store.edgeSecret(for: record)
        let file = store.secretFile(peerPin: outcome.peer.pin)
        _ = store.writeLegacyFilesForRollback()
        backdate(file)
        var before = stat(); _ = lstat(file.path, &before)
        let kept = store.writeLegacyFilesForRollback()
        var unchanged = stat(); _ = lstat(file.path, &unchanged)
        expect(unchanged.st_ino == before.st_ino && kept.first?.contains("there already") == true, "without rewrite a file there is kept")
        _ = store.writeLegacyFilesForRollback(rewrite: true)
        var after = stat(); _ = lstat(file.path, &after)
        expect(after.st_ino != before.st_ino && after.st_mtimespec.tv_sec >= Int(ClusterPairingStore.processStart),
               "rewrite makes a new file, newer than this process's start")
        expectEqual(contents(file), hexLine(outcome.edgeSecret), "with the same key in 0.10.12's format")
        expectEqual(try? store.edgeSecret(for: record), outcome.edgeSecret, "a process started before it reads the item")
        expectEqual(contents(file), hexLine(outcome.edgeSecret), "and leaves the file")
    }

    /// This Mac's real Keychain, with a throwaway service: skipped where the build is not entitled (every unsigned
    /// build, CI's included), as the Secure Enclave key's tests are.
    static func keychainReal() {
        let vault = ClusterKeychainEdgeSecretVault(service: "io.darkbloom.test.cluster-edge-secret." + UUID().uuidString.lowercased(),
                                                   accessGroup: "SLDQ2GJ6TL.io.darkbloom.provider")
        let pin = String(repeating: "ab", count: 32)
        let item = ClusterEdgeSecretItem(secret: Data((0..<32).map { UInt8($0) | 0x40 }), binding: "link-epoch test edge test")
        switch vault.add(peerPin: pin, item) {
        case .failed(.notEntitled):
            print("     (real Keychain: skipped, this build has no keychain-access-groups entitlement)")
            expect(true, "skipped"); return
        case let other:
            expectEqual(other, .done, "real Keychain: add")
        }
        defer { _ = vault.delete(peerPin: pin) }
        expectEqual(vault.read(peerPin: pin), .found(item), "real Keychain: reads back")
        if case .success(let protection?) = vault.protection(peerPin: pin) {
            expect(protection.afterFirstUnlockThisDeviceOnly, "real Keychain: after first unlock, this device only, not synchronised")
            expectEqual(protection.accessGroup, "SLDQ2GJ6TL.io.darkbloom.provider", "real Keychain: the app's access group")
        } else { expect(false, "real Keychain: attributes") }
        expectEqual(vault.add(peerPin: pin, item), .exists, "real Keychain: a second add finds the first")
        expectEqual(vault.delete(peerPin: pin), .done, "real Keychain: delete")
        expectEqual(vault.read(peerPin: pin), .absent, "real Keychain: gone")
    }
}

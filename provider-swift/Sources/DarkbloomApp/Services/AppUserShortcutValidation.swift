import Foundation
import ProviderCoreFoundation

extension AppUserShortcutTransaction {
    func synchronizedOwnedState(
        at url: URL,
        expected: AppRelocationArtifactState? = nil,
        description: String
    ) throws -> AppRelocationArtifactState {
        guard try AppRelocationFilesystem.pathKind(at: url) == .directory,
              isOwnedApp(url)
        else {
            throw ambiguous("\(description) is no longer a Darkbloom-owned app")
        }
        let state = try AppRelocationFilesystem.synchronizedState(at: url)
        if let expected, state != expected {
            throw ambiguous("\(description) changed from its recorded state")
        }
        guard isOwnedApp(url),
              try AppRelocationFilesystem.optionalState(at: url) == state
        else {
            throw ambiguous("\(description) changed while ownership was verified")
        }
        return state
    }

    func isCorrectShortcut(at url: URL) throws -> Bool {
        guard try AppRelocationFilesystem.pathKind(at: url) == .symbolicLink else {
            return false
        }
        do {
            return try fileManager.destinationOfSymbolicLink(atPath: url.path)
                == managedAppURL.path
        } catch {
            throw filesystem("read symbolic link \(url.path)", error: error)
        }
    }

    func currentRootIdentities() throws -> (
        install: String,
        shortcut: String
    ) {
        guard installRoot != shortcutRoot,
              managedAppURL.deletingLastPathComponent() == installRoot,
              shortcutURL.deletingLastPathComponent() == shortcutRoot
        else {
            throw TransactionError.invalidRoot(
                path: shortcutRoot.path,
                reason: "configured transaction paths are not canonical direct children"
            )
        }
        let install = try requiredDirectoryIdentity(
            installRoot,
            description: "managed install directory"
        )
        let shortcut = try requiredDirectoryIdentity(
            shortcutRoot,
            description: "user Applications directory"
        )
        guard install != shortcut else {
            throw TransactionError.invalidRoot(
                path: shortcutRoot.path,
                reason: "install and shortcut roots resolve to the same directory inode"
            )
        }
        return (install, shortcut)
    }

    private func requiredDirectoryIdentity(
        _ url: URL,
        description: String
    ) throws -> String {
        guard try AppRelocationFilesystem.pathKind(at: url) == .directory,
              let identity = try AppRelocationFilesystem.optionalIdentity(at: url)
        else {
            throw TransactionError.invalidRoot(
                path: url.path,
                reason: "\(description) is not a real directory"
            )
        }
        return identity
    }

    func verifyRootIdentities(
        install: String,
        shortcut: String
    ) throws {
        try verifyRootIdentity(
            installRoot,
            expected: install,
            description: "managed install directory"
        )
        try verifyRootIdentity(
            shortcutRoot,
            expected: shortcut,
            description: "user Applications directory"
        )
    }

    func verifyRootIdentity(
        _ root: URL,
        expected: String,
        description: String
    ) throws {
        guard try AppRelocationFilesystem.pathKind(at: root) == .directory,
              try AppRelocationFilesystem.optionalIdentity(at: root) == expected
        else {
            throw TransactionError.invalidRoot(
                path: root.path,
                reason: "\(description) was replaced while recovery was pending"
            )
        }
    }

    func readJournal() throws -> Journal {
        let data: Data
        do {
            data = try AppRelocationFilesystem.readRegularFile(
                journalURL,
                maximumBytes: Self.maximumJournalBytes
            )
        } catch {
            throw corrupt(error.localizedDescription)
        }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: data)
            try validate(journal)
            return journal
        } catch let error as TransactionError {
            throw error
        } catch {
            throw corrupt(error.localizedDescription)
        }
    }

    func persist(_ journal: Journal) throws {
        try validate(journal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try AppRelocationFilesystem.writeAtomically(
                encoder.encode(journal),
                to: journalURL
            )
        } catch {
            throw filesystem("persist \(journalURL.path)", error: error)
        }
    }

    func removeJournal() throws {
        try AppRelocationFilesystem.removeDurably(journalURL)
        try faultInjector(.journalRemoved)
    }

    func validate(_ journal: Journal) throws {
        guard journal.schema == Self.schema else {
            throw corrupt("unsupported schema \(journal.schema)")
        }
        guard journal.kind == Self.journalKind else {
            throw corrupt("unexpected transaction kind \(journal.kind)")
        }
        guard Self.isCanonicalTransactionID(journal.transactionID) else {
            throw corrupt("transaction identifier is not a canonical UUID")
        }
        guard Self.isValidIdentity(journal.installRootIdentity),
              Self.isValidIdentity(journal.shortcutRootIdentity),
              journal.installRootIdentity != journal.shortcutRootIdentity
        else {
            throw corrupt("recorded root identity is invalid")
        }
        if let candidate = journal.candidate,
           !Self.isValidArtifactState(candidate) {
            throw corrupt("shortcut candidate identity or content hash is invalid")
        }
        if let previous = journal.previous,
           !Self.isValidArtifactState(previous) {
            throw corrupt("shortcut predecessor identity or content hash is invalid")
        }
        if let candidate = journal.candidate,
           let previous = journal.previous,
           candidate.identity == previous.identity {
            throw corrupt("shortcut candidate and predecessor share one inode")
        }

        switch journal.operation {
        case .install:
            guard journal.candidate != nil else {
                throw corrupt("install transaction has no shortcut candidate")
            }
            guard journal.phase != .staleBackupRestored else {
                throw corrupt("install transaction has a stale-backup phase")
            }
        case .restoreStaleBackup:
            guard journal.candidate == nil, journal.previous != nil else {
                throw corrupt("stale-backup restoration has invalid artifacts")
            }
            guard journal.phase == .prepared
                    || journal.phase == .staleBackupRestored
            else {
                throw corrupt("stale-backup restoration has an invalid phase")
            }
        case .retireStaleBackup:
            guard journal.candidate == nil, journal.previous != nil else {
                throw corrupt("stale-backup retirement has invalid artifacts")
            }
            guard journal.phase == .prepared
                    || journal.phase == .backupRemovalAuthorized
                    || journal.phase == .backupRemoved
            else {
                throw corrupt("stale-backup retirement has an invalid phase")
            }
        }
    }

    static func transactionID(
        in name: String,
        prefix: String
    ) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let value = String(name.dropFirst(prefix.count))
        return isCanonicalTransactionID(value) ? value : nil
    }

    static func isCanonicalTransactionID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isValidArtifactState(
        _ state: AppRelocationArtifactState
    ) -> Bool {
        isValidIdentity(state.identity)
            && state.contentHash.utf8.count == 64
            && state.contentHash.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy {
            !$0.isEmpty
                && $0.allSatisfy(\.isNumber)
                && UInt64($0) != nil
        }
    }

    func corrupt(_ reason: String) -> TransactionError {
        .corruptJournal(path: journalURL.path, reason: reason)
    }

    func ambiguous(_ reason: String) -> TransactionError {
        .ambiguousRecovery(path: journalURL.path, reason: reason)
    }

    func filesystem(
        _ operation: String,
        error: Error
    ) -> TransactionError {
        .filesystem(operation: operation, reason: error.localizedDescription)
    }
}

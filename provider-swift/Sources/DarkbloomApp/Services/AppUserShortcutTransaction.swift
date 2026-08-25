import Foundation
import ProviderCoreFoundation

/// Restart-safe replacement of `~/Applications/Darkbloom.app`.
///
/// The shortcut transaction deliberately shares the app relocation journal and
/// mutation lock. Only one install mutation can therefore need recovery at a
/// time, and the CLI/shell installers continue to recognize the fixed journal
/// as app-owned recovery state.
struct AppUserShortcutTransaction {
    enum FaultPoint: String, CaseIterable {
        case candidatePrepared
        case journalPersisted
        case previousShortcutMoved
        case previousShortcutMoveRecorded
        case candidateShortcutMoved
        case candidateShortcutMoveRecorded
        case backupRemovalAuthorized
        case backupRemoved
        case backupRemovalRecorded
        case staleBackupRestored
        case staleBackupRestoreRecorded
        case journalRemoved
    }

    struct RecoveryResult: Equatable {
        let installedShortcut: Bool
    }

    enum TransactionError: Error, LocalizedError {
        case pendingTransaction(path: String)
        case corruptJournal(path: String, reason: String)
        case ambiguousRecovery(path: String, reason: String)
        case invalidRoot(path: String, reason: String)
        case filesystem(operation: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .pendingTransaction(let path):
                "A Darkbloom install transaction already needs recovery at \(path)."
            case .corruptJournal(let path, let reason):
                "The user shortcut transaction at \(path) is invalid: \(reason)"
            case .ambiguousRecovery(let path, let reason):
                "The user shortcut transaction at \(path) cannot be recovered "
                    + "without risking user data: \(reason)"
            case .invalidRoot(let path, let reason):
                "Darkbloom refused to mutate the user shortcut root at \(path): \(reason)"
            case .filesystem(let operation, let reason):
                "The user shortcut transaction could not \(operation): \(reason)"
            }
        }
    }

    enum Operation: String, Codable {
        case install
        case restoreStaleBackup = "restore_stale_backup"
        case retireStaleBackup = "retire_stale_backup"
    }

    enum Phase: String, Codable {
        case prepared
        case previousMoved = "previous_moved"
        case shortcutInstalled = "shortcut_installed"
        case backupRemovalAuthorized = "backup_removal_authorized"
        case backupRemoved = "backup_removed"
        case staleBackupRestored = "stale_backup_restored"
    }

    struct Journal: Codable {
        let schema: Int
        let kind: String
        let transactionID: String
        let operation: Operation
        var phase: Phase
        let installRootIdentity: String
        let shortcutRootIdentity: String
        let candidate: AppRelocationArtifactState?
        let previous: AppRelocationArtifactState?

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case transactionID = "transaction_id"
            case operation
            case phase
            case installRootIdentity = "install_root_identity"
            case shortcutRootIdentity = "shortcut_root_identity"
            case candidate
            case previous
        }
    }

    private struct KindEnvelope: Decodable {
        let kind: String?
    }

    static let schema = 1
    static let journalKind = "user_shortcut"
    static let candidatePrefix = ".Darkbloom.app.shortcut-"
    static let backupPrefix = ".Darkbloom.app.shortcut-backup-"
    static let maximumJournalBytes = 64 * 1024

    let installRoot: URL
    let managedAppURL: URL
    let shortcutRoot: URL
    let shortcutURL: URL
    let fileManager: FileManager
    let isOwnedApp: (URL) -> Bool
    let faultInjector: (FaultPoint) throws -> Void

    init(
        installRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        isOwnedApp: @escaping (URL) -> Bool,
        faultInjector: @escaping (FaultPoint) throws -> Void = { _ in }
    ) {
        self.installRoot = installRoot.standardizedFileURL
        managedAppURL = installRoot
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
            .standardizedFileURL
        shortcutRoot = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        shortcutURL = shortcutRoot
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
        self.isOwnedApp = isOwnedApp
        self.faultInjector = faultInjector
    }

    static func pendingJournalIsShortcut(
        in installRoot: URL
    ) throws -> Bool {
        let journal = InstallMutationLock.appRelocationTransactionURL(
            in: installRoot
        )
        guard AppRelocationFilesystem.itemExists(journal) else {
            return false
        }
        let data: Data
        do {
            data = try AppRelocationFilesystem.readRegularFile(
                journal,
                maximumBytes: maximumJournalBytes
            )
        } catch {
            // Let the relocation transaction report a malformed legacy
            // journal. A valid shortcut journal always has a decodable kind.
            return false
        }
        return (try? JSONDecoder().decode(KindEnvelope.self, from: data).kind)
            == journalKind
    }

    /// Recover any recorded shortcut operation, adopt stale artifacts from
    /// the pre-journal implementation, and converge the destination when it is
    /// absent or Darkbloom-owned. A foreign destination is never modified.
    func converge(transactionID: String) throws -> RecoveryResult {
        if try Self.pendingJournalIsShortcut(in: installRoot) {
            _ = try recover()
        }
        guard !AppRelocationFilesystem.itemExists(journalURL) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }

        _ = try currentRootIdentities()
        try cleanUnjournaledCandidates()
        try recoverStaleBackups()

        if try isCorrectShortcut(at: shortcutURL) {
            return RecoveryResult(installedShortcut: true)
        }
        if AppRelocationFilesystem.itemExists(shortcutURL),
           !isOwnedApp(shortcutURL)
        {
            return RecoveryResult(installedShortcut: false)
        }

        return try beginInstall(transactionID: transactionID)
    }

    func recover() throws -> RecoveryResult? {
        guard AppRelocationFilesystem.itemExists(journalURL) else {
            return nil
        }
        guard try Self.pendingJournalIsShortcut(in: installRoot) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }
        var journal = try readJournal()
        return try complete(&journal)
    }

    var journalURL: URL {
        InstallMutationLock.appRelocationTransactionURL(in: installRoot)
    }

    func candidateURL(transactionID: String) -> URL {
        shortcutRoot.appendingPathComponent(
            "\(Self.candidatePrefix)\(transactionID)"
        ).standardizedFileURL
    }

    func backupURL(transactionID: String) -> URL {
        shortcutRoot.appendingPathComponent(
            "\(Self.backupPrefix)\(transactionID)",
            isDirectory: true
        ).standardizedFileURL
    }

    func candidateURL(for journal: Journal) -> URL {
        candidateURL(transactionID: journal.transactionID)
    }

    func backupURL(for journal: Journal) -> URL {
        backupURL(transactionID: journal.transactionID)
    }

    private func beginInstall(
        transactionID: String
    ) throws -> RecoveryResult {
        guard Self.isCanonicalTransactionID(transactionID) else {
            throw corrupt("transaction identifier is not a canonical UUID")
        }
        let roots = try currentRootIdentities()
        let candidate = candidateURL(transactionID: transactionID)
        let backup = backupURL(transactionID: transactionID)
        guard !AppRelocationFilesystem.itemExists(candidate),
              !AppRelocationFilesystem.itemExists(backup)
        else {
            throw ambiguous(
                "the selected shortcut transaction namespace is already occupied"
            )
        }

        let previous: AppRelocationArtifactState?
        if AppRelocationFilesystem.itemExists(shortcutURL) {
            guard isOwnedApp(shortcutURL) else {
                return RecoveryResult(installedShortcut: false)
            }
            previous = try synchronizedOwnedState(
                at: shortcutURL,
                description: "existing user shortcut app"
            )
        } else {
            previous = nil
        }

        do {
            try fileManager.createSymbolicLink(
                atPath: candidate.path,
                withDestinationPath: managedAppURL.path
            )
        } catch {
            throw filesystem(
                "create staged shortcut at \(candidate.path)",
                error: error
            )
        }
        let candidateState = try AppRelocationFilesystem.synchronizedState(
            at: candidate
        )
        guard try isCorrectShortcut(at: candidate) else {
            throw ambiguous("the staged shortcut does not target the managed app")
        }
        try verifyRootIdentities(
            install: roots.install,
            shortcut: roots.shortcut
        )
        try faultInjector(.candidatePrepared)

        var journal = Journal(
            schema: Self.schema,
            kind: Self.journalKind,
            transactionID: transactionID,
            operation: .install,
            phase: .prepared,
            installRootIdentity: roots.install,
            shortcutRootIdentity: roots.shortcut,
            candidate: candidateState,
            previous: previous
        )
        try validate(journal)
        try persist(journal)
        try faultInjector(.journalPersisted)
        return try complete(&journal)
    }

    func complete(
        _ journal: inout Journal
    ) throws -> RecoveryResult {
        while true {
            try validate(journal)
            try verifyRootIdentities(
                install: journal.installRootIdentity,
                shortcut: journal.shortcutRootIdentity
            )
            switch journal.operation {
            case .install:
                if let result = try completeInstallStep(&journal) {
                    return result
                }
            case .restoreStaleBackup:
                if let result = try completeRestoreStep(&journal) {
                    return result
                }
            case .retireStaleBackup:
                if let result = try completeRetirementStep(&journal) {
                    return result
                }
            }
        }
    }

    private func completeInstallStep(
        _ journal: inout Journal
    ) throws -> RecoveryResult? {
        switch journal.phase {
        case .prepared:
            try movePreviousShortcut(journal)
            journal.phase = .previousMoved
            try persist(journal)
            try faultInjector(.previousShortcutMoveRecorded)
        case .previousMoved:
            if try publishCandidateShortcut(journal) {
                journal.phase = .shortcutInstalled
                try persist(journal)
                try faultInjector(.candidateShortcutMoveRecorded)
            } else {
                try removeJournal()
                return RecoveryResult(installedShortcut: false)
            }
        case .shortcutInstalled:
            try verifyInstalledShortcut(journal)
            if journal.previous != nil {
                try authorizeBackupRemoval(journal)
                journal.phase = .backupRemovalAuthorized
                try persist(journal)
                try faultInjector(.backupRemovalAuthorized)
            } else {
                journal.phase = .backupRemoved
                try persist(journal)
                try faultInjector(.backupRemovalRecorded)
            }
        case .backupRemovalAuthorized:
            try removeAuthorizedBackup(journal)
            try faultInjector(.backupRemoved)
            journal.phase = .backupRemoved
            try persist(journal)
            try faultInjector(.backupRemovalRecorded)
        case .backupRemoved:
            try verifyFinishedInstall(journal)
            try removeJournal()
            return RecoveryResult(installedShortcut: true)
        case .staleBackupRestored:
            throw corrupt("install transaction has a stale-backup phase")
        }
        return nil
    }

    private func movePreviousShortcut(_ journal: Journal) throws {
        guard let previous = journal.previous else {
            guard try AppRelocationFilesystem.optionalState(at: shortcutURL) == nil,
                  try AppRelocationFilesystem.optionalState(
                    at: backupURL(for: journal)
                  ) == nil
            else {
                throw ambiguous(
                    "fresh shortcut destination or backup unexpectedly exists"
                )
            }
            return
        }

        let destinationState = try AppRelocationFilesystem.optionalState(
            at: shortcutURL
        )
        let backupState = try AppRelocationFilesystem.optionalState(
            at: backupURL(for: journal)
        )
        if destinationState == previous, backupState == nil {
            _ = try synchronizedOwnedState(
                at: shortcutURL,
                expected: previous,
                description: "user shortcut predecessor"
            )
            try AppRelocationFilesystem.renameExclusive(
                shortcutURL,
                to: backupURL(for: journal)
            )
            try faultInjector(.previousShortcutMoved)
        } else if destinationState == nil, backupState == previous {
            _ = try synchronizedOwnedState(
                at: backupURL(for: journal),
                expected: previous,
                description: "backed-up user shortcut predecessor"
            )
        } else {
            throw ambiguous(
                "owned shortcut predecessor is not exactly live or backed up"
            )
        }
    }

    /// Returns false after safely rolling back an unavailable candidate.
    private func publishCandidateShortcut(_ journal: Journal) throws -> Bool {
        guard let candidate = journal.candidate else {
            throw corrupt("install transaction has no shortcut candidate")
        }
        let stagedState = try AppRelocationFilesystem.optionalState(
            at: candidateURL(for: journal)
        )
        let destinationState = try AppRelocationFilesystem.optionalState(
            at: shortcutURL
        )

        if stagedState == candidate, destinationState == nil {
            guard try isCorrectShortcut(at: candidateURL(for: journal)) else {
                throw ambiguous("staged shortcut target changed before publication")
            }
            try AppRelocationFilesystem.renameExclusive(
                candidateURL(for: journal),
                to: shortcutURL
            )
            try faultInjector(.candidateShortcutMoved)
            return true
        }
        if stagedState == nil, destinationState == candidate {
            guard try isCorrectShortcut(at: shortcutURL) else {
                throw ambiguous("published shortcut target changed during recovery")
            }
            return true
        }

        // If the candidate disappeared after the predecessor was backed up,
        // restore the authenticated predecessor. The next launch can stage a
        // fresh shortcut without ever stranding the user's app.
        if stagedState != candidate,
           destinationState == nil,
           let previous = journal.previous,
           try AppRelocationFilesystem.optionalState(
               at: backupURL(for: journal)
           ) == previous
        {
            _ = try synchronizedOwnedState(
                at: backupURL(for: journal),
                expected: previous,
                description: "shortcut predecessor selected for restoration"
            )
            try AppRelocationFilesystem.renameExclusive(
                backupURL(for: journal),
                to: shortcutURL
            )
            try faultInjector(.staleBackupRestored)
            return false
        }
        if destinationState == journal.previous,
           let previous = journal.previous,
           try AppRelocationFilesystem.optionalState(
               at: backupURL(for: journal)
           ) == nil
        {
            _ = try synchronizedOwnedState(
                at: shortcutURL,
                expected: previous,
                description: "restored shortcut predecessor"
            )
            return false
        }

        throw ambiguous(
            "shortcut candidate is not exactly staged, published, or safely rolled back"
        )
    }

    private func verifyInstalledShortcut(_ journal: Journal) throws {
        guard let candidate = journal.candidate,
              try AppRelocationFilesystem.optionalState(at: shortcutURL)
                == candidate,
              try AppRelocationFilesystem.optionalState(
                at: candidateURL(for: journal)
              ) == nil,
              try isCorrectShortcut(at: shortcutURL)
        else {
            throw ambiguous("published shortcut changed before predecessor cleanup")
        }
    }

    func authorizeBackupRemoval(_ journal: Journal) throws {
        guard let previous = journal.previous,
              try AppRelocationFilesystem.optionalState(
                at: backupURL(for: journal)
              ) == previous
        else {
            throw ambiguous("owned shortcut backup changed before cleanup authorization")
        }
        _ = try synchronizedOwnedState(
            at: backupURL(for: journal),
            expected: previous,
            description: "owned shortcut backup"
        )
    }

    func removeAuthorizedBackup(_ journal: Journal) throws {
        guard let previous = journal.previous else {
            throw corrupt("backup removal is authorized without a predecessor")
        }
        guard let identity = try AppRelocationFilesystem.optionalIdentity(
            at: backupURL(for: journal)
        ) else {
            return
        }
        guard identity == previous.identity else {
            throw ambiguous(
                "shortcut backup was replaced after cleanup authorization"
            )
        }
        // Ownership and the full content state were durably authorized before
        // recursive removal began. A restart may therefore continue a partial
        // removal by root inode even when the signature tree is incomplete.
        try AppRelocationFilesystem.removeDurably(backupURL(for: journal))
    }

    private func verifyFinishedInstall(_ journal: Journal) throws {
        try verifyInstalledShortcut(journal)
        guard try AppRelocationFilesystem.optionalState(
            at: backupURL(for: journal)
        ) == nil else {
            throw ambiguous("owned shortcut backup cleanup is incomplete")
        }
    }

}

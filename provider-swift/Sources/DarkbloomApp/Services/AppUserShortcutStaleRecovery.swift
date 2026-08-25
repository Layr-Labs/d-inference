import Foundation

extension AppUserShortcutTransaction {
    /// Adopt backups left by the pre-journal implementation one at a time.
    /// Lexical UUID ordering makes restoration deterministic when more than
    /// one owned backup exists.
    func recoverStaleBackups() throws {
        while true {
            let roots = try currentRootIdentities()
            let entries = try shortcutEntries()
                .filter {
                    Self.transactionID(
                        in: $0.lastPathComponent,
                        prefix: Self.backupPrefix
                    ) != nil
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var adopted = false
            for backup in entries {
                if try isCorrectShortcut(at: backup) {
                    try removeVerifiedSymlink(
                        backup,
                        expectedRootIdentity: roots.shortcut
                    )
                    adopted = true
                    break
                }
                guard isOwnedApp(backup) else {
                    continue
                }
                guard let transactionID = Self.transactionID(
                    in: backup.lastPathComponent,
                    prefix: Self.backupPrefix
                ) else {
                    continue
                }
                let previous = try synchronizedOwnedState(
                    at: backup,
                    description: "stale owned shortcut backup"
                )
                try verifyRootIdentities(
                    install: roots.install,
                    shortcut: roots.shortcut
                )
                let operation: Operation = AppRelocationFilesystem.itemExists(
                    shortcutURL
                ) ? .retireStaleBackup : .restoreStaleBackup
                var journal = Journal(
                    schema: Self.schema,
                    kind: Self.journalKind,
                    transactionID: transactionID,
                    operation: operation,
                    phase: .prepared,
                    installRootIdentity: roots.install,
                    shortcutRootIdentity: roots.shortcut,
                    candidate: nil,
                    previous: previous
                )
                try validate(journal)
                try persist(journal)
                try faultInjector(.journalPersisted)
                _ = try complete(&journal)
                adopted = true
                break
            }
            if !adopted {
                return
            }
        }
    }

    func completeRestoreStep(
        _ journal: inout Journal
    ) throws -> RecoveryResult? {
        guard let previous = journal.previous else {
            throw corrupt("stale-backup restoration has no recorded backup")
        }
        switch journal.phase {
        case .prepared:
            let backupState = try AppRelocationFilesystem.optionalState(
                at: backupURL(for: journal)
            )
            let destinationState = try AppRelocationFilesystem.optionalState(
                at: shortcutURL
            )
            if backupState == previous, destinationState == nil {
                _ = try synchronizedOwnedState(
                    at: backupURL(for: journal),
                    expected: previous,
                    description: "stale shortcut backup selected for restoration"
                )
                try AppRelocationFilesystem.renameExclusive(
                    backupURL(for: journal),
                    to: shortcutURL
                )
                try faultInjector(.staleBackupRestored)
            } else if backupState == nil, destinationState == previous {
                _ = try synchronizedOwnedState(
                    at: shortcutURL,
                    expected: previous,
                    description: "restored stale shortcut backup"
                )
            } else {
                throw ambiguous(
                    "stale shortcut backup is not exactly backed up or restored"
                )
            }
            journal.phase = .staleBackupRestored
            try persist(journal)
            try faultInjector(.staleBackupRestoreRecorded)
        case .staleBackupRestored:
            guard try AppRelocationFilesystem.optionalState(
                at: backupURL(for: journal)
            ) == nil,
                  try AppRelocationFilesystem.optionalState(at: shortcutURL)
                    == previous
            else {
                throw ambiguous("restored stale shortcut backup changed")
            }
            _ = try synchronizedOwnedState(
                at: shortcutURL,
                expected: previous,
                description: "restored stale shortcut backup"
            )
            try removeJournal()
            return RecoveryResult(installedShortcut: false)
        case .previousMoved, .shortcutInstalled, .backupRemovalAuthorized,
             .backupRemoved:
            throw corrupt("stale-backup restoration has an install-only phase")
        }
        return nil
    }

    func completeRetirementStep(
        _ journal: inout Journal
    ) throws -> RecoveryResult? {
        switch journal.phase {
        case .prepared:
            try authorizeBackupRemoval(journal)
            journal.phase = .backupRemovalAuthorized
            try persist(journal)
            try faultInjector(.backupRemovalAuthorized)
        case .backupRemovalAuthorized:
            try removeAuthorizedBackup(journal)
            try faultInjector(.backupRemoved)
            journal.phase = .backupRemoved
            try persist(journal)
            try faultInjector(.backupRemovalRecorded)
        case .backupRemoved:
            guard try AppRelocationFilesystem.optionalState(
                at: backupURL(for: journal)
            ) == nil else {
                throw ambiguous("stale owned shortcut backup cleanup is incomplete")
            }
            try removeJournal()
            return RecoveryResult(
                installedShortcut: (try? isCorrectShortcut(at: shortcutURL))
                    == true
            )
        case .previousMoved, .shortcutInstalled, .staleBackupRestored:
            throw corrupt("stale-backup retirement has an incompatible phase")
        }
        return nil
    }

    func cleanUnjournaledCandidates() throws {
        let roots = try currentRootIdentities()
        for candidate in try shortcutEntries().sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            guard Self.transactionID(
                in: candidate.lastPathComponent,
                prefix: Self.candidatePrefix
            ) != nil,
                  try isCorrectShortcut(at: candidate)
            else {
                continue
            }
            try removeVerifiedSymlink(
                candidate,
                expectedRootIdentity: roots.shortcut
            )
        }
    }

    private func removeVerifiedSymlink(
        _ url: URL,
        expectedRootIdentity: String
    ) throws {
        guard try AppRelocationFilesystem.pathKind(at: url) == .symbolicLink,
              try isCorrectShortcut(at: url)
        else {
            return
        }
        let expected = try AppRelocationFilesystem.state(at: url)
        try verifyRootIdentity(
            shortcutRoot,
            expected: expectedRootIdentity,
            description: "user Applications directory"
        )
        guard try AppRelocationFilesystem.optionalState(at: url) == expected else {
            throw ambiguous("stale shortcut symlink changed before cleanup")
        }
        try AppRelocationFilesystem.removeDurably(url)
    }

    private func shortcutEntries() throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: shortcutRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw filesystem(
                "inspect user shortcut artifacts in \(shortcutRoot.path)",
                error: error
            )
        }
    }
}

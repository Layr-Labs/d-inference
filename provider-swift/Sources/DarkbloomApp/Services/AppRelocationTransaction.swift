import CryptoKit
import Darwin
import Foundation
import ProviderCoreFoundation

/// Crash- and power-loss-durable publication of a verified app bundle.
///
/// Callers must hold `InstallMutationLock.acquireForOneShotInstall` for every
/// operation. The fixed journal is deliberately visible to the CLI updater and
/// shell installer so neither can mutate the install while this transaction
/// needs recovery.
struct AppRelocationTransaction {
    enum FaultPoint: String, CaseIterable {
        case journalPersisted
        case liveStateMutated
        case liveStateRecorded
        case previousStateMoved
        case previousStateRecorded
        case ownedPreviousRemoved
        case journalRemoved
    }

    enum PreviousKind: String, Codable {
        case absent
        case owned
        case foreign
    }

    struct RecoveryResult: Equatable {
        let preservedForeignApp: URL?
    }

    enum TransactionError: Error, LocalizedError {
        case pendingTransaction(path: String)
        case corruptJournal(path: String, reason: String)
        case ambiguousRecovery(path: String, reason: String)
        case invalidStaging(path: String)
        case filesystem(operation: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .pendingTransaction(let path):
                "An app relocation transaction already needs recovery at \(path)."
            case .corruptJournal(let path, let reason):
                "The app relocation journal at \(path) is invalid: \(reason)"
            case .ambiguousRecovery(let path, let reason):
                "The app relocation transaction at \(path) cannot be recovered "
                    + "without risking user data: \(reason)"
            case .invalidStaging(let path):
                "The verified app staging path is outside the managed transaction "
                    + "namespace: \(path)"
            case .filesystem(let operation, let reason):
                "The app relocation transaction could not \(operation): \(reason)"
            }
        }
    }

    private enum Phase: String, Codable {
        case prepared
        case liveInstalled = "live_installed"
        case previousResolved = "previous_resolved"
    }

    fileprivate struct ArtifactState: Codable, Equatable {
        let identity: String
        let contentHash: String

        enum CodingKeys: String, CodingKey {
            case identity
            case contentHash = "content_hash"
        }
    }

    private struct Journal: Codable {
        let schema: Int
        let transactionID: String
        var phase: Phase
        let candidate: ArtifactState
        let previousKind: PreviousKind
        let previous: ArtifactState?

        enum CodingKeys: String, CodingKey {
            case schema
            case transactionID = "transaction_id"
            case phase
            case candidate
            case previousKind = "previous_kind"
            case previous
        }
    }

    private static let schema = 1
    private static let stagingPrefix = ".Darkbloom.app.relocation-"
    private static let previousPrefix = ".Darkbloom.app.previous-"
    private static let foreignPrefix = "Darkbloom.app.foreign-"
    private static let journalTemporaryPrefix =
        ".\(InstallMutationLock.appRelocationTransactionFileName).tmp-"
    private static let maximumJournalBytes = 64 * 1024

    private let installRoot: URL
    private let destinationURL: URL
    private let fileManager: FileManager
    private let faultInjector: (FaultPoint) throws -> Void

    init(
        installRoot: URL,
        fileManager: FileManager = .default,
        faultInjector: @escaping (FaultPoint) throws -> Void = { _ in }
    ) {
        self.installRoot = installRoot.standardizedFileURL
        self.destinationURL = installRoot
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    static func hasPendingTransaction(
        in installRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        DurableFilesystem.itemExists(
            InstallMutationLock.appRelocationTransactionURL(in: installRoot)
        )
    }

    /// Complete the single recorded transaction, or return nil when there is
    /// no journal. Every accepted state is identified by both inode identity
    /// and a complete content hash; all other combinations fail closed.
    func recover() throws -> RecoveryResult? {
        guard Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            return nil
        }
        var journal = try readJournal()
        return try complete(&journal)
    }

    /// Remove only unjournaled artifacts from this helper's strict UUID
    /// namespace. This runs under the install lock, so none can belong to a
    /// concurrently staging app process.
    func cleanupUnjournaledArtifacts() throws {
        guard !Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: installRoot,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw TransactionError.filesystem(
                operation: "inspect app relocation artifacts",
                reason: error.localizedDescription
            )
        }

        var removedAny = false
        for entry in entries {
            let name = entry.lastPathComponent
            let suffix: String?
            if name.hasPrefix(Self.stagingPrefix) {
                suffix = String(name.dropFirst(Self.stagingPrefix.count))
            } else if name.hasPrefix(Self.journalTemporaryPrefix) {
                suffix = String(name.dropFirst(Self.journalTemporaryPrefix.count))
            } else {
                suffix = nil
            }
            guard let suffix, Self.isCanonicalTransactionID(suffix) else {
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
                removedAny = true
            } catch {
                throw TransactionError.filesystem(
                    operation: "remove orphaned app relocation artifact \(entry.path)",
                    reason: error.localizedDescription
                )
            }
        }
        if removedAny {
            try DurableFilesystem.syncDirectory(installRoot)
        }
    }

    /// Publish `stagingURL` as the live app. Ownership of the staging path
    /// transfers to the transaction once the journal has been published.
    func install(
        stagingURL: URL,
        previousKind: PreviousKind
    ) throws -> RecoveryResult {
        guard !Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }

        let staging = stagingURL.standardizedFileURL
        guard staging.deletingLastPathComponent() == installRoot,
              staging.lastPathComponent.hasPrefix(Self.stagingPrefix)
        else {
            throw TransactionError.invalidStaging(path: staging.path)
        }
        let transactionID = String(
            staging.lastPathComponent.dropFirst(Self.stagingPrefix.count)
        )
        guard Self.isCanonicalTransactionID(transactionID) else {
            throw TransactionError.invalidStaging(path: staging.path)
        }

        try DurableFilesystem.fullySyncTree(staging)
        let candidate = try DurableFilesystem.state(at: staging)
        let previous = try DurableFilesystem.optionalState(at: destinationURL)
        switch previousKind {
        case .absent:
            guard previous == nil else {
                throw ambiguous(
                    "destination appeared after ownership classification"
                )
            }
        case .owned, .foreign:
            guard previous != nil else {
                throw ambiguous(
                    "destination disappeared after ownership classification"
                )
            }
        }

        let journal = Journal(
            schema: Self.schema,
            transactionID: transactionID,
            phase: .prepared,
            candidate: candidate,
            previousKind: previousKind,
            previous: previous
        )
        try validate(journal)
        try ensureInitialAuxiliaryPathIsAvailable(for: journal)
        try persist(journal)
        try faultInjector(.journalPersisted)

        var mutableJournal = journal
        return try complete(&mutableJournal)
    }

    private var journalURL: URL {
        InstallMutationLock.appRelocationTransactionURL(in: installRoot)
    }

    private func stagingURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.stagingPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func previousURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.previousPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func foreignURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.foreignPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func complete(_ journal: inout Journal) throws -> RecoveryResult {
        while true {
            try validate(journal)
            switch journal.phase {
            case .prepared:
                try installLiveCandidate(journal)
                journal.phase = .liveInstalled
                try persist(journal)
                try faultInjector(.liveStateRecorded)
            case .liveInstalled:
                try resolvePrevious(journal)
                journal.phase = .previousResolved
                try persist(journal)
                try faultInjector(.previousStateRecorded)
            case .previousResolved:
                let result = try finish(journal)
                try DurableFilesystem.removeDurably(journalURL)
                try faultInjector(.journalRemoved)
                return result
            }
        }
    }

    private func installLiveCandidate(_ journal: Journal) throws {
        let staging = stagingURL(for: journal)
        let destination = try DurableFilesystem.optionalState(at: destinationURL)
        let staged = try DurableFilesystem.optionalState(at: staging)

        switch journal.previousKind {
        case .absent:
            guard journal.previous == nil else {
                throw corrupt("absent predecessor carries a recorded state")
            }
            if staged == journal.candidate, destination == nil {
                try DurableFilesystem.renameExclusive(
                    staging,
                    to: destinationURL
                )
                try faultInjector(.liveStateMutated)
            } else if staged == nil, destination == journal.candidate {
                // The rename reached disk before the phase journal did.
            } else {
                throw ambiguous(
                    "fresh install is neither wholly staged nor wholly live"
                )
            }
        case .owned, .foreign:
            guard let previous = journal.previous else {
                throw corrupt("existing predecessor has no recorded state")
            }
            if staged == journal.candidate, destination == previous {
                try DurableFilesystem.exchange(staging, destinationURL)
                try faultInjector(.liveStateMutated)
            } else if staged == previous, destination == journal.candidate {
                // The exchange reached disk before the phase journal did.
            } else {
                throw ambiguous(
                    "replacement endpoints do not match either side of the "
                        + "recorded atomic exchange"
                )
            }
        }
    }

    private func resolvePrevious(_ journal: Journal) throws {
        guard try DurableFilesystem.optionalState(at: destinationURL)
                == journal.candidate
        else {
            throw ambiguous("live destination no longer matches the candidate")
        }

        let staging = stagingURL(for: journal)
        switch journal.previousKind {
        case .absent:
            guard journal.previous == nil,
                  try DurableFilesystem.optionalState(at: staging) == nil
            else {
                throw ambiguous("fresh install unexpectedly has a predecessor")
            }
        case .owned:
            guard let previous = journal.previous else {
                throw corrupt("owned predecessor has no recorded state")
            }
            let retired = previousURL(for: journal)
            let stagedState = try DurableFilesystem.optionalState(at: staging)
            let retiredState = try DurableFilesystem.optionalState(at: retired)
            if stagedState == previous, retiredState == nil {
                try DurableFilesystem.renameExclusive(staging, to: retired)
                try faultInjector(.previousStateMoved)
            } else if stagedState == nil, retiredState == previous {
                // The retirement rename reached disk before the phase journal.
            } else {
                throw ambiguous(
                    "owned predecessor is not exactly at its staged or retired path"
                )
            }
        case .foreign:
            guard let previous = journal.previous else {
                throw corrupt("foreign predecessor has no recorded state")
            }
            let preserved = foreignURL(for: journal)
            let stagedState = try DurableFilesystem.optionalState(at: staging)
            let preservedState = try DurableFilesystem.optionalState(at: preserved)
            if stagedState == previous, preservedState == nil {
                try DurableFilesystem.renameExclusive(staging, to: preserved)
                try faultInjector(.previousStateMoved)
            } else if stagedState == nil, preservedState == previous {
                // The preservation rename reached disk before the phase journal.
            } else {
                throw ambiguous(
                    "foreign predecessor is not preserved exactly once"
                )
            }
        }
    }

    private func finish(_ journal: Journal) throws -> RecoveryResult {
        guard try DurableFilesystem.optionalState(at: destinationURL)
                == journal.candidate
        else {
            throw ambiguous("committed destination no longer matches the candidate")
        }
        guard try DurableFilesystem.optionalState(
            at: stagingURL(for: journal)
        ) == nil else {
            throw ambiguous("transaction staging path still exists after resolution")
        }

        switch journal.previousKind {
        case .absent:
            guard journal.previous == nil else {
                throw corrupt("absent predecessor carries a recorded state")
            }
            return RecoveryResult(preservedForeignApp: nil)
        case .foreign:
            guard let previous = journal.previous,
                  try DurableFilesystem.optionalState(
                    at: foreignURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("preserved foreign app changed or disappeared")
            }
            return RecoveryResult(
                preservedForeignApp: foreignURL(for: journal)
            )
        case .owned:
            guard journal.previous != nil else {
                throw corrupt("owned predecessor has no recorded state")
            }
            // `previousResolved` is persisted only after the complete
            // predecessor was verified at this transaction-owned path. A
            // restart may therefore continue a partially completed recursive
            // deletion without mistaking it for foreign live content.
            try DurableFilesystem.removeDurably(previousURL(for: journal))
            try faultInjector(.ownedPreviousRemoved)
            return RecoveryResult(preservedForeignApp: nil)
        }
    }

    private func ensureInitialAuxiliaryPathIsAvailable(
        for journal: Journal
    ) throws {
        let path: URL?
        switch journal.previousKind {
        case .absent:
            path = nil
        case .owned:
            path = previousURL(for: journal)
        case .foreign:
            path = foreignURL(for: journal)
        }
        if let path, DurableFilesystem.itemExists(path) {
            throw ambiguous(
                "transaction auxiliary path already exists at \(path.path)"
            )
        }
    }

    private func readJournal() throws -> Journal {
        let data: Data
        do {
            data = try DurableFilesystem.readRegularFile(
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

    private func persist(_ journal: Journal) throws {
        try validate(journal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try DurableFilesystem.writeAtomically(
                encoder.encode(journal),
                to: journalURL
            )
        } catch {
            throw TransactionError.filesystem(
                operation: "persist \(journalURL.path)",
                reason: error.localizedDescription
            )
        }
    }

    private func validate(_ journal: Journal) throws {
        guard journal.schema == Self.schema else {
            throw corrupt("unsupported schema \(journal.schema)")
        }
        guard Self.isCanonicalTransactionID(journal.transactionID) else {
            throw corrupt("transaction identifier is not a canonical UUID")
        }
        guard Self.isValidArtifactState(journal.candidate) else {
            throw corrupt("candidate identity or content hash is invalid")
        }
        switch journal.previousKind {
        case .absent:
            guard journal.previous == nil else {
                throw corrupt("absent predecessor includes state")
            }
        case .owned, .foreign:
            guard let previous = journal.previous,
                  Self.isValidArtifactState(previous)
            else {
                throw corrupt("existing predecessor state is invalid")
            }
        }
    }

    private static func isCanonicalTransactionID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isValidArtifactState(_ state: ArtifactState) -> Bool {
        isValidIdentity(state.identity) && isLowercaseSHA256(state.contentHash)
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

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private func corrupt(_ reason: String) -> TransactionError {
        .corruptJournal(path: journalURL.path, reason: reason)
    }

    private func ambiguous(_ reason: String) -> TransactionError {
        .ambiguousRecovery(path: journalURL.path, reason: reason)
    }
}

private enum DurableFilesystem {
    static func itemExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func optionalState(
        at url: URL
    ) throws -> AppRelocationTransaction.ArtifactState? {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw filesystemError("inspect \(url.path)")
        }
        return try state(at: url, initialStatus: status)
    }

    static func state(
        at url: URL
    ) throws -> AppRelocationTransaction.ArtifactState {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw filesystemError("inspect \(url.path)")
        }
        return try state(at: url, initialStatus: status)
    }

    static func fullySyncTree(_ root: URL) throws {
        let entries = try treeEntries(root)
        var directories: [URL] = []
        for entry in entries {
            var status = stat()
            guard lstat(entry.path, &status) == 0 else {
                throw filesystemError("inspect \(entry.path)")
            }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                let descriptor = open(
                    entry.path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else {
                    throw filesystemError("open \(entry.path) for full sync")
                }
                do {
                    var openedStatus = stat()
                    guard fstat(descriptor, &openedStatus) == 0 else {
                        throw filesystemError(
                            "inspect \(entry.path) before full sync"
                        )
                    }
                    guard openedStatus.st_mode & mode_t(S_IFMT)
                            == mode_t(S_IFREG)
                    else {
                        throw filesystemError(
                            "refuse non-regular full sync at \(entry.path)",
                            code: EFTYPE
                        )
                    }
                    try fullSync(descriptor, path: entry.path)
                    guard close(descriptor) == 0 else {
                        throw filesystemError("close \(entry.path) after full sync")
                    }
                } catch {
                    _ = close(descriptor)
                    throw error
                }
            case mode_t(S_IFDIR):
                directories.append(entry)
            case mode_t(S_IFLNK):
                continue
            default:
                throw filesystemError(
                    "refuse unsupported file type at \(entry.path)",
                    code: EFTYPE
                )
            }
        }
        for directory in directories.sorted(by: {
            $0.pathComponents.count > $1.pathComponents.count
        }) {
            try syncDirectory(directory)
        }
        try syncDirectory(root.deletingLastPathComponent())
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw filesystemError("create \(temporary.path)")
        }
        var descriptorIsOpen = true
        var shouldRemove = true
        defer {
            if descriptorIsOpen {
                _ = close(descriptor)
            }
            if shouldRemove {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw filesystemError("write \(temporary.path)")
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        try fullSync(descriptor, path: temporary.path)
        guard close(descriptor) == 0 else {
            throw filesystemError("close \(temporary.path)")
        }
        descriptorIsOpen = false
        guard rename(temporary.path, destination.path) == 0 else {
            throw filesystemError(
                "publish \(temporary.path) as \(destination.path)"
            )
        }
        shouldRemove = false
        try syncDirectory(directory)
    }

    static func readRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open \(url.path)")
        }
        defer { _ = close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw filesystemError("inspect \(url.path)")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw filesystemError(
                "refuse non-regular journal at \(url.path)",
                code: EFTYPE
            )
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumBytes)
        else {
            throw filesystemError(
                "refuse oversized journal at \(url.path)",
                code: EFBIG
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw filesystemError("read \(url.path)")
            }
            if count == 0 {
                return data
            }
            guard data.count + count <= maximumBytes else {
                throw filesystemError(
                    "refuse oversized journal at \(url.path)",
                    code: EFBIG
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func exchange(_ first: URL, _ second: URL) throws {
        guard first.deletingLastPathComponent().standardizedFileURL
                == second.deletingLastPathComponent().standardizedFileURL
        else {
            throw filesystemError(
                "refuse cross-directory app exchange",
                code: EXDEV
            )
        }
        guard renameatx_np(
            AT_FDCWD,
            first.path,
            AT_FDCWD,
            second.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw filesystemError("exchange \(first.path) with \(second.path)")
        }
        try syncDirectory(first.deletingLastPathComponent())
    }

    static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard source.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL
        else {
            throw filesystemError(
                "refuse cross-directory app rename",
                code: EXDEV
            )
        }
        guard renameatx_np(
            AT_FDCWD,
            source.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw filesystemError(
                "rename \(source.path) to \(destination.path)"
            )
        }
        try syncDirectory(source.deletingLastPathComponent())
    }

    static func removeDurably(_ url: URL) throws {
        guard itemExists(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AppRelocationTransaction.TransactionError.filesystem(
                operation: "remove \(url.path)",
                reason: error.localizedDescription
            )
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open directory \(directory.path) for sync")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let saved = errno
            _ = close(descriptor)
            throw filesystemError(
                "inspect directory \(directory.path) for sync",
                code: saved
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            _ = close(descriptor)
            throw filesystemError(
                "refuse non-directory sync at \(directory.path)",
                code: ENOTDIR
            )
        }
        let result = fsync(descriptor)
        let saved = errno
        _ = close(descriptor)
        guard result == 0 else {
            throw filesystemError(
                "sync directory \(directory.path)",
                code: saved
            )
        }
    }

    private static func state(
        at url: URL,
        initialStatus: stat
    ) throws -> AppRelocationTransaction.ArtifactState {
        let initialIdentity = identity(of: initialStatus)
        let hash = try treeHash(root: url)
        var finalStatus = stat()
        guard lstat(url.path, &finalStatus) == 0 else {
            throw filesystemError("reinspect \(url.path) after hashing")
        }
        guard identity(of: finalStatus) == initialIdentity else {
            throw filesystemError(
                "refuse \(url.path), which changed while hashing",
                code: EBUSY
            )
        }
        return AppRelocationTransaction.ArtifactState(
            identity: initialIdentity,
            contentHash: hash
        )
    }

    private static func identity(of status: stat) -> String {
        "\(UInt64(status.st_dev)):\(UInt64(status.st_ino))"
    }

    private static func treeHash(root: URL) throws -> String {
        let entries = try treeEntries(root).sorted {
            relativePath($0, under: root) < relativePath($1, under: root)
        }
        var hasher = SHA256()
        for entry in entries {
            var status = stat()
            guard lstat(entry.path, &status) == 0 else {
                throw filesystemError("inspect \(entry.path) while hashing")
            }
            let relative = relativePath(entry, under: root)
            let permissions = String(status.st_mode & mode_t(0o7777))
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                hashFields(["directory", relative, permissions], into: &hasher)
            case mode_t(S_IFLNK):
                let target: String
                do {
                    target = try FileManager.default.destinationOfSymbolicLink(
                        atPath: entry.path
                    )
                } catch {
                    throw AppRelocationTransaction.TransactionError.filesystem(
                        operation: "read symbolic link \(entry.path)",
                        reason: error.localizedDescription
                    )
                }
                hashFields(
                    ["symlink", relative, permissions, target],
                    into: &hasher
                )
            case mode_t(S_IFREG):
                hashFields(
                    [
                        "file",
                        relative,
                        permissions,
                        try regularFileHash(entry),
                    ],
                    into: &hasher
                )
            default:
                throw filesystemError(
                    "refuse unsupported file type at \(entry.path)",
                    code: EFTYPE
                )
            }
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func regularFileHash(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open \(url.path) for hashing")
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw filesystemError("refuse non-regular file at \(url.path)")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw filesystemError("read \(url.path) for hashing")
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func treeEntries(_ root: URL) throws -> [URL] {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else {
            throw filesystemError("inspect tree root \(root.path)")
        }
        var entries = [root]
        guard rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return entries
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw filesystemError(
                "enumerate \(root.path)",
                code: EIO
            )
        }
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
        if let enumerationError {
            throw AppRelocationTransaction.TransactionError.filesystem(
                operation: "enumerate \(root.path)",
                reason: enumerationError.localizedDescription
            )
        }
        return entries
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        if url.standardizedFileURL == root.standardizedFileURL {
            return "."
        }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            return path
        }
        return String(path.dropFirst(rootPath.count))
    }

    private static func hashFields(
        _ fields: [String],
        into hasher: inout SHA256
    ) {
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) {
                hasher.update(data: Data($0))
            }
            hasher.update(data: data)
        }
    }

    private static func fullSync(_ descriptor: Int32, path: String) throws {
        guard fsync(descriptor) == 0 else {
            throw filesystemError("sync \(path)")
        }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw filesystemError("fully sync \(path)")
        }
    }

    private static func filesystemError(
        _ operation: String,
        code: Int32 = errno
    ) -> AppRelocationTransaction.TransactionError {
        .filesystem(
            operation: operation,
            reason: String(cString: strerror(code))
        )
    }
}

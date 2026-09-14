import Darwin
import Foundation
import SandboxRuntime

/// The privileged operator owns this directory. Persist intent before touching
/// a guest disk; a boot intent permanently closes the staging recovery path.
/// This journal never grants source/image authority or publishes readiness.
final class AccountlessInstallationStagingJournal {
    private let directory: URL
    private let descriptor: Int32
    private let lock: Int32
    private let intent: Data
    let candidate: AccountlessBaseCandidateRecord
    let plan: AccountlessInstallationPayloadPlan

    init(directory: URL, candidate: AccountlessBaseCandidateRecord,
         plan: AccountlessInstallationPayloadPlan) throws {
        try plan.validate(candidate: candidate)
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        let lock = openat(descriptor, "staging.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 || errno == EEXIST else { close(descriptor); throw AccountlessInstallationError.unsafeDestination }
        let activeLock = lock >= 0 ? lock : openat(descriptor, "staging.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        var owned = false
        defer { if !owned { if activeLock >= 0 { close(activeLock) }; close(descriptor) } }
        guard activeLock >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(activeLock, maximumBytes: 0)
        guard flock(activeLock, LOCK_EX | LOCK_NB) == 0 else { throw AccountlessInstallationError.stagingInProgress }
        try Self.requireNamed(activeLock, parent: descriptor, name: "staging.lock")
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        self.directory = directory; self.descriptor = descriptor; self.lock = activeLock
        self.candidate = candidate; self.plan = plan
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        intent = try encoder.encode(Intent(schemaVersion: 1, candidate: candidate, plan: plan))
        owned = true
        try requireStagingAllowed()
        try publishMatching(intent, name: "staging-intent.json")
    }

    deinit { close(lock); close(descriptor) }

    func requireStagingAllowed() throws {
        try requireBoundDirectory()
        for name in ["boot-intent.json", "installation-result.json", "cleanup-intent.json", "cleaned.json"] {
            var metadata = stat()
            if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                throw AccountlessInstallationError.stagingClosed
            }
            guard errno == ENOENT else { throw AccountlessInstallationError.unsafeDestination }
        }
        let existingIntent = try read("staging-intent.json")
        if let existing = existingIntent, existing != intent {
            throw AccountlessInstallationError.invalidBinding
        }
        if let existing = try read("staged.json") {
            guard existingIntent != nil, existing == (try stagedData()) else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
    }

    func recordStaged() throws {
        try requireStagingAllowed()
        // The caller has verified every staged file and the boot job. The
        // receipt records that observation, never inferring a guest boot.
        try publishMatching(stagedData(), name: "staged.json")
    }

    func isStaged() throws -> Bool {
        try requireStagingAllowed()
        return try read("staged.json") != nil
    }

    private func stagedData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Staged(schemaVersion: 1, intentSHA256: BaseGuestRelease.digest(intent)))
    }

    private func publishMatching(_ data: Data, name: String) throws {
        guard data.count <= 32 * 1024 else { throw AccountlessInstallationError.invalidBinding }
        if let existing = try read(name) {
            guard existing == data else { throw AccountlessInstallationError.invalidBinding }
            return
        }
        let temporary = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: descriptor, prefix: "staging")
        defer { close(temporary) }
        try SandboxAuthorityFileSystem.writeAll(data, to: temporary)
        try SandboxAuthorityFileSystem.synchronize(temporary)
        guard fclonefileat(temporary, descriptor, name, 0) == 0 else { throw AccountlessInstallationError.unsafeDestination }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        guard try read(name) == data else { throw AccountlessInstallationError.invalidBinding }
    }

    private func read(_ name: String) throws -> Data? {
        try requireBoundDirectory()
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 32 * 1024)
        try Self.requireNamed(file, parent: descriptor, name: name)
        return data
    }

    private func requireBoundDirectory() throws {
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessInstallationError.unsafeDestination }
        try Self.requireNamed(lock, parent: descriptor, name: "staging.lock")
    }

    private static func requireNamed(_ file: Int32, parent: Int32, name: String) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named)
        else { throw AccountlessInstallationError.unsafeDestination }
    }

    private struct Intent: Codable { let schemaVersion: Int; let candidate: AccountlessBaseCandidateRecord; let plan: AccountlessInstallationPayloadPlan }
    private struct Staged: Codable { let schemaVersion: Int; let intentSHA256: String }
}

import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// The stopped proof and original directory identity survive outside the tree
/// being erased. Presence fences every new create/start/execute for that name.
struct LumeVirtualMachineDeletionIntent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let name: String
    let scope: SandboxOperationScope?
    let installationID: UUID
    let directoryDevice: Int64
    let directoryInode: UInt64
    let stoppedVerified: Bool

    static func requireAbsent(workspace: LumeRuntimeWorkspace, name: String) throws {
        guard try load(workspace: workspace, name: name) == nil else {
            throw failure("VM has a pending deletion")
        }
    }

    func requireMatching(name: String, scope: SandboxOperationScope?) throws {
        guard schemaVersion == 1, stoppedVerified, self.name == name, directoryInode > 0 else {
            throw Self.failure("invalid deletion intent")
        }
        switch (self.scope, scope) {
        case (.none, .none): return
        case (.some(let original), .some(let current)):
            // A renewed/fenced token may complete an already-stopped deletion,
            // after the caller has independently authorized the current lease.
            guard original.sandboxID == current.sandboxID, original.generation == current.generation else {
                throw Self.failure("deletion intent belongs to a different generation")
            }
        default: throw Self.failure("deletion intent belongs to a different owner")
        }
    }

    static func persist(workspace: LumeRuntimeWorkspace, name: String,
                        scope: SandboxOperationScope?, installationID: UUID) throws -> Self {
        try workspace.prepare()
        let owner = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: workspace.storageDirectory.appendingPathComponent(name), createIfMissing: false)
        defer { close(owner) }
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(owner)
        let intent = Self(schemaVersion: 1, name: name, scope: scope, installationID: installationID,
            directoryDevice: Int64(metadata.st_dev), directoryInode: UInt64(metadata.st_ino), stoppedVerified: true)
        if let existing = try load(workspace: workspace, name: name) {
            guard existing == intent else { throw failure("deletion intent conflicts with the owned VM") }
            return existing
        }
        let root = try openRoot(workspace: workspace, create: true)
        guard let root else { throw failure("deletion intent root is unavailable") }
        defer { close(root) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try LumeGuestCommandJournalIO.writeExclusive(encoder.encode(intent), named: name + ".json", parentDescriptor: root)
        try SandboxAuthorityFileSystem.synchronize(root)
        return intent
    }

    static func load(workspace: LumeRuntimeWorkspace, name: String) throws -> Self? {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw SandboxRuntimeError.invalidName }
        guard let root = try openRoot(workspace: workspace, create: false) else { return nil }
        defer { close(root) }
        guard let bytes = try LumeGuestCommandJournalIO.readFileIfPresent(named: name + ".json",
            parentDescriptor: root, maximumBytes: 16384) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.requireMatching(name: name, scope: value.scope)
        return value
    }

    static func pending(workspace: LumeRuntimeWorkspace) throws -> [Self] {
        guard let root = try openRoot(workspace: workspace, create: false) else { return [] }
        defer { close(root) }
        let copy = dup(root)
        guard copy >= 0 else { throw failure("could not enumerate deletion intents") }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw failure("could not enumerate deletion intents")
        }
        defer { closedir(directory) }
        var values: [Self] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw failure("could not enumerate deletion intents") }
                break
            }
            let filename = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard filename != ".", filename != ".." else { continue }
            guard filename.hasSuffix(".json"), values.count < 1024 else {
                throw failure("unexpected deletion intent entry")
            }
            let name = String(filename.dropLast(5))
            guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw failure("invalid deletion intent name") }
            guard let bytes = try LumeGuestCommandJournalIO.readFileIfPresent(
                named: filename, parentDescriptor: root, maximumBytes: 16384) else { continue }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            try value.requireMatching(name: name, scope: value.scope)
            values.append(value)
        }
        return values.sorted { $0.name < $1.name }
    }

    func clear(workspace: LumeRuntimeWorkspace) throws {
        guard let root = try Self.openRoot(workspace: workspace, create: false) else {
            throw Self.failure("deletion intent disappeared")
        }
        defer { close(root) }
        guard try Self.load(workspace: workspace, name: name) == self else {
            throw Self.failure("deletion intent changed")
        }
        guard unlinkat(root, name + ".json", 0) == 0 else { throw Self.failure("could not clear deletion intent") }
        try SandboxAuthorityFileSystem.synchronize(root)
    }

    func confirmDurable(workspace: LumeRuntimeWorkspace,
                        synchronizeDirectory: (Int32) throws -> Void) throws {
        guard let root = try Self.openRoot(workspace: workspace, create: false) else {
            throw Self.failure("deletion intent disappeared")
        }
        defer { close(root) }
        let descriptor = openat(root, name + ".json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.failure("deletion intent is unavailable") }
        defer { close(descriptor) }
        let bytes = try SandboxAuthorityFileSystem.readStablePrivateFile(descriptor, maximumBytes: 16384)
        guard try JSONDecoder().decode(Self.self, from: bytes) == self else {
            throw Self.failure("deletion intent changed")
        }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        try synchronizeDirectory(root)
    }

    private static func openRoot(workspace: LumeRuntimeWorkspace, create: Bool) throws -> Int32? {
        if !create {
            var metadata = stat()
            if lstat(workspace.storageDirectory.path, &metadata) != 0, errno == ENOENT { return nil }
        }
        let storage: Int32
        do {
            storage = try SandboxAuthorityFileSystem.openPrivateDirectory(at: workspace.storageDirectory,
                createIfMissing: false)
        } catch SandboxAuthorityFileSystemError.io(let code) where !create && code == ENOENT { return nil }
        defer { close(storage) }
        let support: Int32
        if create {
            support = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: storage,
                name: LumeRuntimeWorkspace.supportDirectoryName, createIfMissing: true)
        } else {
            guard let existing = try LumeGuestCommandJournalIO.openDirectoryIfPresent(parentDescriptor: storage,
                name: LumeRuntimeWorkspace.supportDirectoryName) else { return nil }
            support = existing
        }
        defer { close(support) }
        if create {
            return try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: support,
                name: "deletions", createIfMissing: true)
        }
        return try LumeGuestCommandJournalIO.openDirectoryIfPresent(parentDescriptor: support, name: "deletions")
    }

    static func failure(_ message: String) -> SandboxRuntimeError {
        .unsupported("VM deletion remains pending: " + message)
    }
}

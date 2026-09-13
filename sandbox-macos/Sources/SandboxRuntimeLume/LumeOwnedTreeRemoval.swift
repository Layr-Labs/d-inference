import Darwin
import Foundation
import SandboxRuntime

struct LumeOwnedTreeRemovalHooks: Sendable {
    var afterEntryRemoval: @Sendable (String) throws -> Void = { _ in }
    var afterDirectoryRemoval: @Sendable () throws -> Void = {}
    var synchronizeIntentDirectory: @Sendable (Int32) throws -> Void = {
        try SandboxAuthorityFileSystem.synchronize($0)
    }
}

extension LumeVirtualMachineDeletionIntent {
    /// Retry only the exact previously-stopped directory. No ownership marker
    /// inside it is needed once a durable deletion intent exists.
    func removeOwnedTree(workspace: LumeRuntimeWorkspace,
                         hooks: LumeOwnedTreeRemovalHooks = .init()) throws {
        // A previously visible publication may have failed directory fsync.
        // Confirm the external recovery proof before removing any more bytes.
        try confirmDurable(workspace: workspace, synchronizeDirectory: hooks.synchronizeIntentDirectory)
        let storage = try SandboxAuthorityFileSystem.openPrivateDirectory(at: workspace.storageDirectory,
            createIfMissing: false)
        defer { close(storage) }
        let directory = openat(storage, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT {
            try SandboxAuthorityFileSystem.synchronize(storage)
            return
        }
        guard directory >= 0 else { throw Self.failure("owned directory is inaccessible") }
        defer { close(directory) }
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(directory)
        guard Int64(metadata.st_dev) == directoryDevice, UInt64(metadata.st_ino) == directoryInode else {
            throw Self.failure("owned directory identity changed")
        }
        try SandboxAuthorityFileSystem.requirePrivateDirectory(directory)
        try Self.removeContents(directory: directory, device: metadata.st_dev, relative: "", hooks: hooks)
        try Self.requireNamedIdentity(parent: storage, name: name, descriptor: directory)
        guard unlinkat(storage, name, AT_REMOVEDIR) == 0 else { throw Self.failure("owned directory removal failed") }
        try hooks.afterDirectoryRemoval()
        try SandboxAuthorityFileSystem.synchronize(storage)
    }

    private static func removeContents(directory: Int32, device: dev_t, relative: String,
                                       hooks: LumeOwnedTreeRemovalHooks) throws {
        let duplicated = dup(directory)
        guard duplicated >= 0, let stream = fdopendir(duplicated) else {
            if duplicated >= 0 { close(duplicated) }
            throw failure("cannot enumerate remaining VM files")
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure("remaining VM enumeration failed") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_dev == device, metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
                throw failure("remaining VM entry ownership changed")
            }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                throw failure("remaining VM tree contains a link or special file")
            }
            let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (type == S_IFDIR ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw failure("remaining VM entry is inaccessible") }
            defer { close(descriptor) }
            let opened = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
            guard SandboxAuthorityFileSystem.sameIdentity(metadata, opened), type != S_IFREG || opened.st_nlink == 1 else {
                throw failure("remaining VM file is linked or changed")
            }
            try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
            let path = relative.isEmpty ? name : relative + "/" + name
            if type == S_IFDIR { try removeContents(directory: descriptor, device: device, relative: path, hooks: hooks) }
            try requireNamedIdentity(parent: directory, name: name, descriptor: descriptor)
            guard unlinkat(directory, name, type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                throw failure("remaining VM entry removal failed")
            }
            try hooks.afterEntryRemoval(path)
        }
        try SandboxAuthorityFileSystem.synchronize(directory)
    }

    private static func requireNamedIdentity(parent: Int32, name: String, descriptor: Int32) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SandboxAuthorityFileSystem.sameIdentity(named, try SandboxAuthorityFileSystem.fileMetadata(descriptor)) else {
            throw failure("remaining VM path changed")
        }
    }
}

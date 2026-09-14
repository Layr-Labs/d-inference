import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// Deletes only the exact journaled temporary files and directories. Missing
/// entries are accepted solely as a prefix of this already-persisted removal.
struct AccountlessTemporaryPayloadRemoval {
    let data: AccountlessOfflineDirectory
    let payload: AccountlessInstallationPayloadPlan
    let plan: AccountlessCollectionRemovalPlan
    var didRemove: (String) throws -> Void = { _ in }

    func run() throws {
        try verifyRemaining()
        let paths = [payload.jobRelativePath] + plan.files.keys.filter { $0 != payload.jobRelativePath }.sorted()
        for path in paths {
            try Task.checkCancellation()
            guard let parent = try parentIfPresent(path) else { continue }
            let name = (path as NSString).lastPathComponent
            guard try parent.contains(name) else { continue }
            try verifyFile(path, parent: parent)
            guard unlinkat(parent.descriptor, name, 0) == 0 else { throw AccountlessInstallationError.unsafeDestination }
            try SandboxAuthorityFileSystem.synchronize(parent.descriptor)
            try didRemove(path)
        }
        let directories = plan.directories.keys.sorted { left, right in
            let lhs = left.split(separator: "/").count, rhs = right.split(separator: "/").count
            return lhs == rhs ? left < right : lhs > rhs
        }
        for path in directories {
            try Task.checkCancellation()
            guard let parent = try parentIfPresent(path) else { continue }
            let name = (path as NSString).lastPathComponent
            guard try parent.contains(name) else { continue }
            let directory = try parent.child(name)
            try verifyDirectory(path, directory: directory)
            guard try directory.names().isEmpty, unlinkat(parent.descriptor, name, AT_REMOVEDIR) == 0 else {
                throw AccountlessInstallationError.unsafeDestination
            }
            try SandboxAuthorityFileSystem.synchronize(parent.descriptor)
            try didRemove(path)
        }
        try requireRemoved()
    }

    func requireRemoved() throws {
        let jobs = try data.descend("Library/LaunchDaemons")
        let root = try data.descend("Library/Application Support/DarkbloomSandboxBootstrap")
        guard try !jobs.contains((payload.jobRelativePath as NSString).lastPathComponent),
              try !root.contains((payload.stageRelativePath as NSString).lastPathComponent) else {
            throw AccountlessInstallationError.unsafeDestination
        }
    }

    private func verifyRemaining() throws {
        for path in plan.directories.keys.sorted() {
            guard let parent = try parentIfPresent(path), try parent.contains((path as NSString).lastPathComponent) else { continue }
            let directory = try parent.child((path as NSString).lastPathComponent)
            try verifyDirectory(path, directory: directory)
            let expected = Set(Set(plan.files.keys).union(plan.directories.keys).filter {
                ($0 as NSString).deletingLastPathComponent == path
            }.map { ($0 as NSString).lastPathComponent })
            guard try directory.names().isSubset(of: expected) else { throw AccountlessInstallationError.unsafeDestination }
        }
        for path in plan.files.keys.sorted() {
            guard let parent = try parentIfPresent(path), try parent.contains((path as NSString).lastPathComponent) else { continue }
            try verifyFile(path, parent: parent)
        }
    }

    private func parentIfPresent(_ path: String) throws -> AccountlessOfflineDirectory? {
        if path == payload.jobRelativePath { return try data.descend("Library/LaunchDaemons") }
        guard path == payload.stageRelativePath || path.hasPrefix(payload.stageRelativePath + "/") else {
            throw AccountlessInstallationError.invalidBinding
        }
        var directory = try data.descend("Library/Application Support/DarkbloomSandboxBootstrap")
        if path == payload.stageRelativePath { return directory }
        let suffix = String((path as NSString).deletingLastPathComponent.dropFirst("Library/Application Support/DarkbloomSandboxBootstrap/".count))
        var current = "Library/Application Support/DarkbloomSandboxBootstrap"
        for part in suffix.split(separator: "/").map(String.init) {
            guard try directory.contains(part) else { return nil }
            directory = try directory.child(part); current += "/" + part
            try verifyDirectory(current, directory: directory)
        }
        return directory
    }

    private func verifyDirectory(_ path: String, directory: AccountlessOfflineDirectory) throws {
        guard let expected = plan.directories[path],
              try expected.matchesMountedDirectory(SandboxAuthorityFileSystem.fileMetadata(directory.descriptor)) else {
            throw AccountlessInstallationError.unsafeDestination
        }
    }
    private func verifyFile(_ path: String, parent: AccountlessOfflineDirectory) throws {
        guard let expected = plan.files[path] else { throw AccountlessInstallationError.invalidBinding }
        let name = (path as NSString).lastPathComponent
        let descriptor = try parent.openFile(name, mode: expected.mode, allowEmpty: true)
        defer { close(descriptor) }
        guard try expected.matchesMountedFile(SandboxAuthorityFileSystem.fileMetadata(descriptor)),
              try BaseGuestRelease.copyAndHash(descriptor, to: nil) == expected.sha256 else { throw AccountlessInstallationError.unsafeDestination }
        try parent.requireNamed(descriptor, name: name)
    }
}

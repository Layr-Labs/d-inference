import Darwin
import Foundation
import SandboxRuntime

/// Copies only the fixed accountless installer paths into an already-authorized
/// Data mount. The boot job is the last publication. Partial matching payloads
/// can resume only while the journal proves no boot attempt has been recorded.
struct AccountlessOfflineOverlay {
    var didPublish: (String) throws -> Void = { _ in }
    var loadRelease: AccountlessInstallationPayload.ReleaseLoader = { try BaseGuestRelease(directory: $0) }

    func stage(dataDirectory: URL, payloadDirectory: URL,
               journal: AccountlessInstallationStagingJournal) throws {
        try Task.checkCancellation()
        try journal.requireStagingAllowed()
        let previouslyStaged = try journal.isStaged()
        let plan = journal.plan
        let source = try AccountlessOfflineDirectory(path: payloadDirectory.appendingPathComponent("data-overlay"))
        try verifyTree(source, files: plan.files, modes: plan, prefix: "", allowMissing: false)
        try requireRelease(payloadDirectory.appendingPathComponent("data-overlay/" + plan.stageRelativePath + "/release"), plan: plan)
        let data = try AccountlessOfflineDirectory(path: dataDirectory)
        let library = try data.child("Library")
        let applications = try library.child("Application Support")
        let jobs = try library.child("LaunchDaemons")
        let jobName = (plan.jobRelativePath as NSString).lastPathComponent
        if try jobs.contains(jobName) {
            try verifyFile(jobs, name: jobName, relative: plan.jobRelativePath, plan: plan)
        } else if previouslyStaged { throw AccountlessInstallationError.unsafeDestination }

        // Preflight existing content before creating or publishing anything.
        let parentName = "DarkbloomSandboxBootstrap"
        let attemptName = plan.binding.bootstrapAttemptID.uuidString.lowercased()
        let stageFiles = Dictionary(uniqueKeysWithValues: plan.files.compactMap { path, hash in
            path.hasPrefix(plan.stageRelativePath + "/")
                ? (String(path.dropFirst(plan.stageRelativePath.count + 1)), hash) : nil
        })
        if try applications.contains(parentName) {
            let parent = try applications.child(parentName)
            if try parent.contains(attemptName) {
                try verifyTree(parent.child(attemptName), files: stageFiles, modes: plan,
                    prefix: plan.stageRelativePath, allowMissing: !previouslyStaged)
            } else if previouslyStaged { throw AccountlessInstallationError.unsafeDestination }
        } else if previouslyStaged { throw AccountlessInstallationError.unsafeDestination }
        try journal.requireStagingAllowed()
        let parent = try applications.child(parentName, create: true)
        let stage = try parent.child(attemptName, create: true)
        let release = try stage.child("release", create: true)
        _ = try release.child("guest", create: true)
        for relative in plan.files.keys.sorted() where relative != plan.jobRelativePath {
            try Task.checkCancellation()
            try journal.requireStagingAllowed()
            let suffix = String(relative.dropFirst(plan.stageRelativePath.count + 1))
            let parentPath = (suffix as NSString).deletingLastPathComponent
            let destination = parentPath.isEmpty ? stage : try stage.descend(parentPath)
            try publishFile(relative, source: source, destination: destination, temporaryDirectory: stage, plan: plan)
        }
        try verifyTree(stage, files: stageFiles, modes: plan, prefix: plan.stageRelativePath, allowMissing: false)
        try data.requireBound(to: dataDirectory)
        try requireRelease(dataDirectory.appendingPathComponent(plan.stageRelativePath + "/release"), plan: plan)
        try Task.checkCancellation()
        try journal.requireStagingAllowed()
        try publishFile(plan.jobRelativePath, source: source, destination: jobs, temporaryDirectory: stage, plan: plan)
        try verifyFile(jobs, name: jobName, relative: plan.jobRelativePath, plan: plan)
        try data.requireBound(to: dataDirectory)
        try journal.recordStaged()
    }

    private func publishFile(_ relative: String, source: AccountlessOfflineDirectory,
                             destination: AccountlessOfflineDirectory, temporaryDirectory: AccountlessOfflineDirectory,
                             plan: AccountlessInstallationPayloadPlan) throws {
        let name = (relative as NSString).lastPathComponent
        if try destination.contains(name) {
            try verifyFile(destination, name: name, relative: relative, plan: plan)
            return
        }
        let sourceParent = try source.descend((relative as NSString).deletingLastPathComponent)
        let file = try sourceParent.openFile(name, mode: plan.fileMode(relative))
        defer { close(file) }
        let temporary = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(
            parentDescriptor: temporaryDirectory.descriptor, prefix: "installer")
        defer { close(temporary) }
        // Keep the detached signature xattrs; do not copy ownership, ACLs or
        // modes from the source. Every published file belongs to this operator.
        guard fcopyfile(file, temporary, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0,
              try BaseGuestRelease.copyAndHash(file, to: temporary) == plan.files[relative],
              fchmod(temporary, mode_t(try plan.fileMode(relative))) == 0 else {
            throw AccountlessInstallationError.copyFailed
        }
        try sourceParent.requireNamed(file, name: name)
        try SandboxAuthorityFileSystem.synchronize(temporary)
        guard fclonefileat(temporary, destination.descriptor, name, 0) == 0 else {
            throw AccountlessInstallationError.copyFailed
        }
        try SandboxAuthorityFileSystem.synchronize(destination.descriptor)
        try verifyFile(destination, name: name, relative: relative, plan: plan)
        try didPublish(relative)
    }

    private func verifyTree(_ directory: AccountlessOfflineDirectory, files: [String: String],
                            modes plan: AccountlessInstallationPayloadPlan, prefix: String,
                            allowMissing: Bool) throws {
        let expectedNames = Set(files.keys.map { String($0.split(separator: "/")[0]) })
        let names = try directory.names()
        guard allowMissing ? names.isSubset(of: expectedNames) : names == expectedNames else {
            throw AccountlessInstallationError.unsafeDestination
        }
        for name in names.sorted() {
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if files[name] != nil {
                try verifyFile(directory, name: name, relative: relative, plan: plan)
            } else {
                let children = Dictionary(uniqueKeysWithValues: files.compactMap { path, hash in
                    path.hasPrefix(name + "/") ? (String(path.dropFirst(name.count + 1)), hash) : nil
                })
                try verifyTree(directory.child(name), files: children, modes: plan,
                    prefix: relative, allowMissing: allowMissing)
            }
        }
    }

    private func verifyFile(_ directory: AccountlessOfflineDirectory, name: String,
                            relative: String, plan: AccountlessInstallationPayloadPlan) throws {
        let file = try directory.openFile(name, mode: plan.fileMode(relative))
        defer { close(file) }
        guard try BaseGuestRelease.copyAndHash(file, to: nil) == plan.files[relative] else {
            throw AccountlessInstallationError.releaseChanged
        }
        try directory.requireNamed(file, name: name)
    }

    private func requireRelease(_ directory: URL, plan: AccountlessInstallationPayloadPlan) throws {
        let release = try loadRelease(directory)
        guard release.manifestSHA256 == plan.binding.payload.releaseManifestSHA256,
              BaseGuestRelease.files.allSatisfy({ release.hashes[$0] == plan.files[plan.stageRelativePath + "/release/guest/" + $0] }) else {
            throw AccountlessInstallationError.releaseChanged
        }
    }
}

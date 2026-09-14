import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

struct AccountlessCollectionRemovalPlan: Codable, Equatable {
    struct File: Codable, Equatable {
        let identity: LumeCandidateDiskIdentity; let mode: UInt16; let sha256: String

        // st_dev identifies the current attachment, not a durable APFS volume.
        // The caller checks volumeUUID and descriptor-relative IO requires all
        // entries to stay on that current mount. Preserve every other identity field.
        func matchesMountedFile(_ value: stat) -> Bool {
            let current = LumeCandidateDiskIdentity(value)
            return current.inode == identity.inode && current.size == identity.size
                && current.modifiedSeconds == identity.modifiedSeconds && current.modifiedNanoseconds == identity.modifiedNanoseconds
                && current.changedSeconds == identity.changedSeconds && current.changedNanoseconds == identity.changedNanoseconds
        }
    }
    struct Directory: Codable, Equatable {
        let device: UInt64; let inode: UInt64; let uid: UInt32; let gid: UInt32; let mode: UInt16
        init(_ value: stat) {
            device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino)
            uid = value.st_uid; gid = value.st_gid; mode = UInt16(value.st_mode & 0o7777)
        }
        func matchesMountedDirectory(_ value: stat) -> Bool {
            let current = Self(value)
            return current.inode == inode && current.uid == uid && current.gid == gid && current.mode == mode
        }
    }
    let schemaVersion: Int
    let permitSHA256: String
    let volumeUUID: UUID
    let files: [String: File]
    let directories: [String: Directory]

    static func directoryPaths(_ plan: AccountlessInstallationPayloadPlan) -> Set<String> {
        Set([plan.stageRelativePath, plan.stageRelativePath + "/release", plan.stageRelativePath + "/release/guest", plan.stageRelativePath + "/result"])
    }
    static func resultPaths(_ plan: AccountlessInstallationPayloadPlan) -> [String] {
        ["receipt.json", "installer.log", "helper.log"].map { plan.stageRelativePath + "/result/" + $0 }
    }
    func validate(boot: AccountlessBootJournal.Record) throws {
        let plan = boot.staging.plan
        guard schemaVersion == 1, permitSHA256 == boot.permitSHA256,
              Set(files.keys) == Set(plan.files.keys).union(Self.resultPaths(plan)),
              Set(directories.keys) == Self.directoryPaths(plan) else { throw AccountlessInstallationError.invalidBinding }
        for (path, file) in files {
            let dynamic = Self.resultPaths(plan).contains(path)
            guard file.mode == (dynamic ? 0o600 : (try plan.fileMode(path))), file.identity.inode > 0,
                  file.identity.size <= Self.maximumBytes(path, plan: plan),
                  BaseGuestRelease.isDigest(file.sha256), dynamic || file.sha256 == plan.files[path] else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
        for directory in directories.values {
            guard directory.uid == geteuid(), directory.mode == 0o700, directory.inode > 0 else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
    }

    static func capture(data: AccountlessOfflineDirectory, boot: AccountlessBootJournal.Record, volumeUUID: UUID) throws -> Self {
        let plan = boot.staging.plan
        var files: [String: File] = [:], directories: [String: Directory] = [:]
        for path in directoryPaths(plan).sorted() {
            let directory = try data.descend(path)
            directories[path] = try .init(SandboxAuthorityFileSystem.fileMetadata(directory.descriptor))
        }
        for path in Set(plan.files.keys).union(resultPaths(plan)).sorted() {
            let dynamic = resultPaths(plan).contains(path)
            let mode: UInt16 = dynamic ? 0o600 : try plan.fileMode(path)
            let parent = try data.descend((path as NSString).deletingLastPathComponent)
            let name = (path as NSString).lastPathComponent
            let descriptor = try parent.openFile(name, mode: mode, maximumBytes: maximumBytes(path, plan: plan),
                allowEmpty: name.hasSuffix(".log") && dynamic)
            defer { close(descriptor) }
            let digest = try BaseGuestRelease.copyAndHash(descriptor, to: nil)
            try parent.requireNamed(descriptor, name: name)
            files[path] = try .init(identity: .init(SandboxAuthorityFileSystem.fileMetadata(descriptor)), mode: mode, sha256: digest)
        }
        let value = Self(schemaVersion: 1, permitSHA256: boot.permitSHA256, volumeUUID: volumeUUID, files: files, directories: directories)
        try value.validate(boot: boot)
        try value.requireExpectedEntries(in: data)
        return value
    }

    private static func maximumBytes(_ path: String, plan: AccountlessInstallationPayloadPlan) -> Int {
        if path == plan.stageRelativePath + "/result/receipt.json" { return 16 * 1024 }
        return resultPaths(plan).contains(path) ? 65536 : 128 * 1_048_576
    }

    func requireExpectedEntries(in data: AccountlessOfflineDirectory) throws {
        for path in directories.keys.sorted() {
            let directory = try data.descend(path)
            let children = Set(Set(files.keys).union(directories.keys).filter {
                ($0 as NSString).deletingLastPathComponent == path
            }.map { ($0 as NSString).lastPathComponent })
            guard try directory.names() == children else { throw AccountlessInstallationError.unsafeDestination }
        }
    }
}

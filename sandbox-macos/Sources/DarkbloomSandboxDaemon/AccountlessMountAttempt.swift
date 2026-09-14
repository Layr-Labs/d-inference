import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

/// One append-only attachment attempt beneath the protected staging journal.
/// An absent intent authorizes no system command. Completion records observations
/// supplied by the owner; it never grants template readiness or installation.
final class AccountlessMountAttempt {
    struct Intent: Codable, Equatable {
        let schemaVersion: Int
        let attemptName: String
        let maintenanceSHA256: String
        let imagePath: String
        let image: LumeCandidateDiskIdentity
        let writable: Bool
        let baseline: [AccountlessAttachmentSnapshot]
    }
    struct Completion: Codable, Equatable {
        let schemaVersion: Int
        let attemptName: String
        let maintenanceSHA256: String
        let intentSHA256: String?
        let image: LumeCandidateDiskIdentity
    }

    let directory: URL
    let mountpoint: URL
    private let descriptor: Int32
    private let maintenanceSHA256: String

    init(directory: URL, maintenanceSHA256: String) throws {
        guard BaseGuestRelease.isDigest(maintenanceSHA256) else { throw AccountlessDiskError.bindingChanged }
        self.directory = directory; mountpoint = directory.appendingPathComponent("Data")
        self.maintenanceSHA256 = maintenanceSHA256
        descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        try validate()
    }
    deinit { close(descriptor) }

    func intent() throws -> Intent? {
        guard let bytes = try read("intent.json") else {
            for name in ["attached.json", "selected.json"] {
                guard try read(name) == nil else { throw AccountlessDiskError.bindingChanged }
            }
            return nil
        }
        let value = try decode(Intent.self, bytes)
        guard value.schemaVersion == 1, value.attemptName == directory.lastPathComponent,
              value.maintenanceSHA256 == maintenanceSHA256,
              URL(fileURLWithPath: value.imagePath).path == value.imagePath, value.imagePath.hasPrefix("/"),
              value.image.inode > 0, value.image.size > 0 else { throw AccountlessDiskError.bindingChanged }
        return value
    }

    func begin(_ intent: Intent) throws {
        try requireOpen()
        guard try self.intent() == nil, intent.schemaVersion == 1, intent.attemptName == directory.lastPathComponent,
              intent.maintenanceSHA256 == maintenanceSHA256 else { throw AccountlessDiskError.bindingChanged }
        try requireEmptyMountpoint(create: true)
        try publish(intent, name: "intent.json")
    }

    func recordAttached(_ image: AccountlessAttachmentSnapshot) throws {
        try requireOpen()
        guard let intent = try intent(), image.attachment.isImage(URL(fileURLWithPath: intent.imagePath)),
              image.image.device == intent.image.device, image.image.inode == intent.image.inode,
              image.image.size == intent.image.size else { throw AccountlessDiskError.bindingChanged }
        try publish(image, name: "attached.json")
    }

    func attached() throws -> AccountlessAttachmentSnapshot? {
        try read("attached.json").map { try decode(AccountlessAttachmentSnapshot.self, $0) }
    }

    func recordSelected(_ binding: AccountlessAPFSVolumeBinding) throws {
        try requireOpen()
        guard let attachment = try attached(), attachment.attachment.devices.contains(binding.wholeDisk),
              attachment.attachment.devices.contains(binding.physicalStore),
              attachment.attachment.devices.contains(binding.container),
              attachment.attachment.devices.contains(binding.dataVolume) else { throw AccountlessDiskError.bindingChanged }
        try publish(binding, name: "selected.json")
    }

    func selected() throws -> AccountlessAPFSVolumeBinding? {
        try read("selected.json").map { try decode(AccountlessAPFSVolumeBinding.self, $0) }
    }

    func completion() throws -> Completion? {
        guard let bytes = try read("completed.json") else { return nil }
        let record = try decode(Completion.self, bytes), intentBytes = try read("intent.json")
        guard record.schemaVersion == 1, record.attemptName == directory.lastPathComponent,
              record.maintenanceSHA256 == maintenanceSHA256,
              record.intentSHA256 == intentBytes.map(BaseGuestRelease.digest), record.image.inode > 0,
              record.image.size > 0 else { throw AccountlessDiskError.bindingChanged }
        return record
    }

    func recordDetached(image: LumeCandidateDiskIdentity) throws {
        try requireEmptyMountpoint(create: false)
        try publish(Completion(schemaVersion: 1, attemptName: directory.lastPathComponent, maintenanceSHA256: maintenanceSHA256,
            intentSHA256: try read("intent.json").map(BaseGuestRelease.digest), image: image), name: "completed.json")
    }

    /// Also handles a crash before intent publication. Such an attempt may
    /// contain only an empty, unmounted Data directory; it never authorizes IO.
    func requireEmptyMountpoint(create: Bool) throws {
        try validate()
        if create {
            let child = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: descriptor,
                name: "Data", createIfMissing: true)
            close(child)
        }
        let child = openat(descriptor, "Data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child < 0, errno == ENOENT, !create { return }
        guard child >= 0 else { throw AccountlessDiskError.unsafeMountpoint }
        defer { close(child) }
        try SandboxAuthorityFileSystem.requirePrivateDirectory(child)
        guard try SandboxAuthorityFileSystem.fileMetadata(child).st_dev == SandboxAuthorityFileSystem.fileMetadata(descriptor).st_dev,
              try FileManager.default.contentsOfDirectory(atPath: mountpoint.path).isEmpty else { throw AccountlessDiskError.unsafeMountpoint }
        try validate()
    }

    func validate() throws {
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessDiskError.bindingChanged }
        var names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix(".mount-record-") && name.hasSuffix(".partial") {
            let value = name.dropFirst(".mount-record-".count).dropLast(".partial".count)
            guard UUID(uuidString: String(value)) != nil else { throw AccountlessDiskError.bindingChanged }
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw AccountlessDiskError.bindingChanged }
            defer { close(file) }
            // Publication unlinks before writing. Only a private, empty inode
            // can be the interrupted create/unlink prefix; never remove bytes.
            let info = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, maximumBytes: 0)
            var named = stat()
            guard info.st_mode & 0o7777 == 0o600, info.st_gid == getegid(), info.st_flags == 0,
                  flistxattr(file, nil, 0, 0) == 0, fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  SandboxAuthorityFileSystem.stableIdentity(info, named), unlinkat(descriptor, name, 0) == 0 else {
                throw AccountlessDiskError.bindingChanged
            }
            try SandboxAuthorityFileSystem.synchronize(descriptor)
        }
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names).isSubset(of: ["Data", "intent.json", "attached.json", "selected.json", "completed.json"]) else {
            throw AccountlessDiskError.bindingChanged
        }
    }

    private func requireOpen() throws {
        guard try completion() == nil else { throw AccountlessDiskError.bindingChanged }
    }

    private func read(_ name: String) throws -> Data? {
        try validate()
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw AccountlessDiskError.bindingChanged }
        defer { close(file) }
        let bytes = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 4 * 1_048_576)
        var named = stat()
        guard fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named) else {
            throw AccountlessDiskError.bindingChanged
        }
        try validate()
        return bytes
    }

    private func publish<T: Encodable>(_ record: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(record)
        guard bytes.count <= 4 * 1_048_576 else { throw AccountlessDiskError.invalidInventory }
        if let existing = try read(name) {
            guard existing == bytes else { throw AccountlessDiskError.bindingChanged }
            return
        }
        let file = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: descriptor, prefix: "mount-record")
        defer { close(file) }
        try SandboxAuthorityFileSystem.writeAll(bytes, to: file)
        try SandboxAuthorityFileSystem.synchronize(file)
        try validate()
        guard fclonefileat(file, descriptor, name, 0) == 0 else { throw AccountlessDiskError.bindingChanged }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        guard try read(name) == bytes else { throw AccountlessDiskError.bindingChanged }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        return try JSONDecoder().decode(type, from: data)
    }
}

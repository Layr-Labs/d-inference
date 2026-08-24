import Darwin
import Foundation

public struct SandboxStorageVolumeIdentity: Codable, Equatable, Sendable {
    public let canonicalPath: String
    public let device: UInt64
    public let inode: UInt64

    public init(canonicalPath: String, device: UInt64, inode: UInt64) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
    }
}

public struct SandboxStorageVolumeReport: Equatable, Sendable {
    public let path: URL
    public let identity: SandboxStorageVolumeIdentity
    public let availableImportantBytes: UInt64

    public init(
        path: URL,
        identity: SandboxStorageVolumeIdentity,
        availableImportantBytes: UInt64
    ) {
        self.path = path
        self.identity = identity
        self.availableImportantBytes = availableImportantBytes
    }
}

public enum SandboxStorageVolumeInspectionError: Error, Equatable, Sendable {
    case invalidPath
    case unsafePath
    case capacityUnavailable
}

public struct SandboxStorageVolumeInspector: Sendable {
    public init() {}

    public func inspect(path: URL) throws -> SandboxStorageVolumeReport {
        guard path.isFileURL,
              path.baseURL == nil,
              path.path.hasPrefix("/")
        else {
            throw SandboxStorageVolumeInspectionError.invalidPath
        }
        let normalized = path.standardizedFileURL
        guard let canonicalPath =
            SandboxAuthorityFileSystem.canonicalPath(for: normalized)
        else {
            throw SandboxStorageVolumeInspectionError.unsafePath
        }
        let descriptor: Int32
        do {
            descriptor = try SandboxAuthorityFileSystem.openExistingDirectory(
                at: normalized
            )
        } catch {
            throw SandboxStorageVolumeInspectionError.unsafePath
        }
        defer { close(descriptor) }
        do {
            try SandboxAuthorityFileSystem.requirePrivateDirectory(descriptor)
        } catch {
            throw SandboxStorageVolumeInspectionError.unsafePath
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SandboxStorageVolumeInspectionError.capacityUnavailable
        }
        var fileSystem = statfs()
        guard fstatfs(descriptor, &fileSystem) == 0 else {
            throw SandboxStorageVolumeInspectionError.capacityUnavailable
        }
        let (available, overflow) = UInt64(fileSystem.f_bavail)
            .multipliedReportingOverflow(by: UInt64(fileSystem.f_bsize))
        guard !overflow else {
            throw SandboxStorageVolumeInspectionError.capacityUnavailable
        }
        return SandboxStorageVolumeReport(
            path: URL(fileURLWithPath: canonicalPath, isDirectory: true),
            identity: SandboxStorageVolumeIdentity(
                canonicalPath: canonicalPath,
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)
            ),
            availableImportantBytes: available
        )
    }
}

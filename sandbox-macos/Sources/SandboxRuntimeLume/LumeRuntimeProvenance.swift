import CryptoKit
import Darwin
import Foundation
import SandboxRuntime

struct ValidatedLumeRuntime: Equatable, Sendable {
    let version: String
    let installationIdentity: LumeFileIdentity
    let provenanceIdentity: LumeFileIdentity
    let files: [String: ValidatedLumeRuntimeFile]
    let directories: [String: LumeFileIdentity]
}

struct ValidatedLumeRuntimeFile: Equatable, Sendable {
    let identity: LumeFileIdentity
    let sha256: String
}

enum LumeRuntimeProvenanceValidator {
    static let fileName = "lume.provenance.json"
    private static let schemaVersion: UInt16 = 3
    private static let maximumProvenanceBytes: Int64 = 16 * 1_024

    static func validate(
        configuration: LumeRuntimeConfiguration
    ) throws -> ValidatedLumeRuntime {
        guard configuration.executable.lastPathComponent == "lume" else {
            throw unsupported("Lume executable must use the audited install layout")
        }
        try LumeRuntimeCodeSignature.validate(
            executable: configuration.executable,
            policy: configuration.trustPolicy
        )
        let installationDirectory = configuration.executable
            .deletingLastPathComponent()
        let runtimeTree = try inspectRuntimeTree(
            at: installationDirectory,
            computeDigests: true
        )
        let provenanceURL = configuration.executable
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
        let provenanceFile = try inspectRegularFile(
            at: provenanceURL,
            maximumBytes: maximumProvenanceBytes,
            requiresExecutableMode: false,
            captureData: true,
            computeDigest: true,
            errorSubject: "Lume provenance"
        )
        let provenance: LumeRuntimeProvenance
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            provenance = try decoder.decode(
                LumeRuntimeProvenance.self,
                from: provenanceFile.data ?? Data()
            )
        } catch {
            throw unsupported("Lume provenance is unreadable")
        }

        guard provenance.schemaVersion == schemaVersion,
              provenance.repository == LumeRuntimeConfiguration.pinnedRepository,
              provenance.commit == LumeRuntimeConfiguration.pinnedCommit,
              provenance.sourcePath == LumeRuntimeConfiguration.pinnedSourcePath,
              provenance.version == LumeRuntimeConfiguration.pinnedVersion,
              provenance.patches == [
                  LumeRuntimeConfiguration.pinnedPatchPath:
                      LumeRuntimeConfiguration.pinnedPatchSHA256
              ],
              Set(provenance.directories).count == provenance.directories.count,
              provenance.directories.allSatisfy(Self.isSafeRelativePath),
              provenance.files.keys.allSatisfy(Self.isSafeRelativePath),
              provenance.files.values.allSatisfy(Self.isSHA256),
              Set(provenance.directories) == Set(runtimeTree.directories.keys),
              Set(provenance.files.keys) == Set(runtimeTree.files.keys),
              provenance.files["lume"] != nil
        else {
            throw unsupported("Lume provenance does not match the audited pin")
        }
        for (path, expectedDigest) in provenance.files {
            guard runtimeTree.files[path]?.sha256 == expectedDigest else {
                throw unsupported(
                    "Lume runtime tree digest does not match its provenance"
                )
            }
        }
        return ValidatedLumeRuntime(
            version: provenance.version,
            installationIdentity: runtimeTree.installationIdentity,
            provenanceIdentity: provenanceFile.identity,
            files: runtimeTree.files,
            directories: runtimeTree.directories
        )
    }

    static func requireUnchanged(
        _ validated: ValidatedLumeRuntime,
        configuration: LumeRuntimeConfiguration
    ) throws {
        do {
            let currentTree = try inspectRuntimeTree(
                at: configuration.executable.deletingLastPathComponent(),
                computeDigests: false
            )
            let provenance = try inspectRegularFile(
                at: configuration.executable
                    .deletingLastPathComponent()
                    .appendingPathComponent(fileName),
                maximumBytes: maximumProvenanceBytes,
                requiresExecutableMode: false,
                captureData: false,
                computeDigest: false,
                errorSubject: "Lume provenance"
            )
            let currentFiles = currentTree.files.mapValues {
                $0.identity
            }
            let validatedFiles = validated.files.mapValues {
                $0.identity
            }
            guard currentTree.installationIdentity
                    == validated.installationIdentity,
                  provenance.identity == validated.provenanceIdentity,
                  currentTree.directories == validated.directories,
                  currentFiles == validatedFiles
            else {
                throw unsupported("Lume runtime changed after validation")
            }
        } catch {
            throw unsupported("Lume runtime changed after validation")
        }
    }

    private static func inspectRuntimeTree(
        at installationDirectory: URL,
        computeDigests: Bool
    ) throws -> InspectedLumeRuntimeTree {
        let installationIdentity = try inspectDirectory(
            at: installationDirectory
        )
        guard let enumerator = FileManager.default.enumerator(
            atPath: installationDirectory.path
        ) else {
            throw unsupported("Lume runtime tree cannot be enumerated")
        }

        var files: [String: ValidatedLumeRuntimeFile] = [:]
        var directories: [String: LumeFileIdentity] = [:]
        while let entry = enumerator.nextObject() {
            guard let relativePath = entry as? String else {
                throw unsupported("Lume runtime tree cannot be enumerated")
            }
            guard isSafeRelativePath(relativePath) else {
                throw unsupported("Lume runtime tree contains an unsafe path")
            }
            let url = installationDirectory.appendingPathComponent(relativePath)

            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw unsupported("Lume runtime tree changed during validation")
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                directories[relativePath] = try inspectDirectory(at: url)
            case S_IFREG:
                if relativePath == fileName {
                    continue
                }
                let file = try inspectRegularFile(
                    at: url,
                    maximumBytes: nil,
                    requiresExecutableMode: relativePath == "lume",
                    captureData: false,
                    computeDigest: computeDigests
                )
                files[relativePath] = ValidatedLumeRuntimeFile(
                    identity: file.identity,
                    sha256: file.sha256
                )
            default:
                enumerator.skipDescendants()
                throw unsupported(
                    "Lume runtime tree contains a non-regular entry"
                )
            }
        }
        guard try inspectDirectory(at: installationDirectory)
                == installationIdentity
        else {
            throw unsupported("Lume runtime tree changed during validation")
        }
        return InspectedLumeRuntimeTree(
            installationIdentity: installationIdentity,
            files: files,
            directories: directories
        )
    }

    private static func inspectDirectory(
        at url: URL
    ) throws -> LumeFileIdentity {
        let descriptor: Int32
        do {
            descriptor =
                try SandboxAuthorityFileSystem.openExistingDirectory(at: url)
        } catch {
            throw unsupported(
                "Lume runtime directory failed path or ACL checks"
            )
        }
        defer { close(descriptor) }
        let metadata: stat
        do {
            metadata = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
            try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        } catch {
            throw unsupported(
                "Lume runtime directory failed ACL checks"
            )
        }
        guard
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o222 == 0
        else {
            throw unsupported(
                "Lume runtime directory failed ownership or mode checks"
            )
        }
        return identity(from: metadata)
    }

    private static func inspectRegularFile(
        at url: URL,
        maximumBytes: Int64?,
        requiresExecutableMode: Bool,
        captureData: Bool,
        computeDigest: Bool,
        errorSubject: String = "Lume runtime file"
    ) throws -> InspectedRegularFile {
        let parentDescriptor: Int32
        do {
            parentDescriptor =
                try SandboxAuthorityFileSystem.openExistingDirectory(
                    at: url.deletingLastPathComponent()
                )
        } catch {
            throw unsupported("\(errorSubject) parent path is unsafe")
        }
        defer { close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw unsupported("\(errorSubject) cannot be opened")
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid() || before.st_uid == 0,
              before.st_mode & 0o222 == 0,
              before.st_nlink == 1,
              before.st_size >= 0,
              maximumBytes.map({ before.st_size <= $0 }) ?? true,
              !requiresExecutableMode || before.st_mode & 0o111 != 0
        else {
            throw unsupported("\(errorSubject) failed ownership or mode checks")
        }
        do {
            try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        } catch {
            throw unsupported("\(errorSubject) failed ACL checks")
        }

        var hasher = SHA256()
        var captured = captureData ? Data() : nil
        if captureData || computeDigest {
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count == 0 {
                    break
                }
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw unsupported("\(errorSubject) cannot be read")
                }
                let chunk = Data(buffer.prefix(count))
                if computeDigest {
                    hasher.update(data: chunk)
                }
                captured?.append(chunk)
            }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              identity(from: before) == identity(from: after),
              after.st_nlink == 1
        else {
            throw unsupported("\(errorSubject) changed during validation")
        }
        do {
            try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        } catch {
            throw unsupported("\(errorSubject) ACL changed during validation")
        }
        return InspectedRegularFile(
            identity: identity(from: after),
            sha256: computeDigest
                ? hasher.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
                : "",
            data: captured
        )
    }

    private static func identity(from metadata: stat) -> LumeFileIdentity {
        LumeFileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: metadata.st_size,
            owner: metadata.st_uid,
            mode: metadata.st_mode,
            modificationSeconds: metadata.st_mtimespec.tv_sec,
            modificationNanoseconds: metadata.st_mtimespec.tv_nsec,
            statusChangeSeconds: metadata.st_ctimespec.tv_sec,
            statusChangeNanoseconds: metadata.st_ctimespec.tv_nsec
        )
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0")
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == SHA256.Digest.byteCount * 2
            && value.allSatisfy {
                $0.isASCII && ($0.isNumber || ("a"..."f").contains($0))
            }
    }

    private static func unsupported(_ message: String) -> SandboxRuntimeError {
        .unsupported(message)
    }
}

private struct LumeRuntimeProvenance: Decodable {
    let schemaVersion: UInt16
    let repository: String
    let commit: String
    let sourcePath: String
    let version: String
    let patches: [String: String]
    let directories: [String]
    let files: [String: String]
}

private struct InspectedLumeRuntimeTree {
    let installationIdentity: LumeFileIdentity
    let files: [String: ValidatedLumeRuntimeFile]
    let directories: [String: LumeFileIdentity]
}

private struct InspectedRegularFile {
    let identity: LumeFileIdentity
    let sha256: String
    let data: Data?
}

struct LumeFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let owner: uid_t
    let mode: mode_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let statusChangeSeconds: Int
    let statusChangeNanoseconds: Int
}

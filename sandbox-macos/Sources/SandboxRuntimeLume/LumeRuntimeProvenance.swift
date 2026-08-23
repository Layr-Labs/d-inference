import CryptoKit
import Darwin
import Foundation
import SandboxRuntime

struct ValidatedLumeRuntime: Equatable, Sendable {
    let version: String
    let executableIdentity: LumeFileIdentity
    let provenanceIdentity: LumeFileIdentity
}

enum LumeRuntimeProvenanceValidator {
    static let fileName = "lume.provenance.json"
    private static let schemaVersion: UInt16 = 1
    private static let maximumProvenanceBytes: Int64 = 16 * 1_024

    static func validate(
        configuration: LumeRuntimeConfiguration
    ) throws -> ValidatedLumeRuntime {
        let executableIdentity: LumeFileIdentity
        do {
            executableIdentity = try identity(
                of: configuration.executable,
                maximumBytes: nil
            )
        } catch {
            throw unsupported("Lume executable failed ownership or mode checks")
        }
        let provenanceURL = configuration.executable
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
        let provenanceIdentity: LumeFileIdentity
        do {
            provenanceIdentity = try identity(
                of: provenanceURL,
                maximumBytes: maximumProvenanceBytes
            )
        } catch {
            throw unsupported("Lume provenance failed ownership or mode checks")
        }
        let provenance: LumeRuntimeProvenance
        do {
            let data = try Data(
                contentsOf: provenanceURL,
                options: [.mappedIfSafe]
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            provenance = try decoder.decode(
                LumeRuntimeProvenance.self,
                from: data
            )
        } catch {
            throw unsupported("Lume provenance is unreadable")
        }

        guard provenance.schemaVersion == schemaVersion,
              provenance.repository == LumeRuntimeConfiguration.pinnedRepository,
              provenance.commit == LumeRuntimeConfiguration.pinnedCommit,
              provenance.sourcePath == LumeRuntimeConfiguration.pinnedSourcePath,
              provenance.version == LumeRuntimeConfiguration.pinnedVersion,
              provenance.binarySha256.count == SHA256.Digest.byteCount * 2,
              provenance.binarySha256.allSatisfy(Self.isLowercaseHex)
        else {
            throw unsupported("Lume provenance does not match the audited pin")
        }
        let digest = try sha256(of: configuration.executable)
        guard digest == provenance.binarySha256 else {
            throw unsupported("Lume executable digest does not match its provenance")
        }
        return ValidatedLumeRuntime(
            version: provenance.version,
            executableIdentity: executableIdentity,
            provenanceIdentity: provenanceIdentity
        )
    }

    static func requireUnchanged(
        _ validated: ValidatedLumeRuntime,
        configuration: LumeRuntimeConfiguration
    ) throws {
        let executableIdentity = try identity(
            of: configuration.executable,
            maximumBytes: nil
        )
        let provenanceIdentity = try identity(
            of: configuration.executable
                .deletingLastPathComponent()
                .appendingPathComponent(fileName),
            maximumBytes: maximumProvenanceBytes
        )
        guard executableIdentity == validated.executableIdentity,
              provenanceIdentity == validated.provenanceIdentity
        else {
            throw unsupported("Lume runtime changed after validation")
        }
    }

    private static func identity(
        of url: URL,
        maximumBytes: Int64?
    ) throws -> LumeFileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0,
              metadata.st_size >= 0
        else {
            throw unsupported("Lume runtime files failed ownership or mode checks")
        }
        if let maximumBytes, metadata.st_size > maximumBytes {
            throw unsupported("Lume provenance exceeds the size limit")
        }
        return LumeFileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: metadata.st_size,
            modificationSeconds: metadata.st_mtimespec.tv_sec,
            modificationNanoseconds: metadata.st_mtimespec.tv_nsec,
            statusChangeSeconds: metadata.st_ctimespec.tv_sec,
            statusChangeNanoseconds: metadata.st_ctimespec.tv_nsec
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw unsupported("Lume executable cannot be opened for hashing")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty
            {
                hasher.update(data: chunk)
            }
        } catch {
            throw unsupported("Lume executable cannot be hashed")
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isLowercaseHex(_ character: Character) -> Bool {
        character.isASCII
            && (character.isNumber || ("a"..."f").contains(character))
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
    let binarySha256: String
}

struct LumeFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let statusChangeSeconds: Int
    let statusChangeNanoseconds: Int
}

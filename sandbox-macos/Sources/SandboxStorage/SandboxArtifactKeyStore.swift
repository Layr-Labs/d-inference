import CryptoKit
import Darwin
import Foundation
import SandboxSecurity

public enum SandboxArtifactKeyStoreError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case destinationExists
    case invalidEnvelope
    case unsupportedVersion(UInt16)
    case contextMismatch
    case keyIdentityMismatch
    case authenticationFailed
    case unsafePermissions(UInt16)
    case unsafeOwner(UInt32)
    case io(String)

    public var description: String {
        switch self {
        case .destinationExists:
            return "wrapped sandbox key destination already exists"
        case .invalidEnvelope:
            return "wrapped sandbox key envelope is malformed"
        case .unsupportedVersion(let version):
            return "unsupported wrapped sandbox key version \(version)"
        case .contextMismatch:
            return "wrapped sandbox key belongs to another sandbox artifact"
        case .keyIdentityMismatch:
            return "wrapped sandbox key belongs to another Secure Enclave identity"
        case .authenticationFailed:
            return "wrapped sandbox key authentication failed"
        case .unsafePermissions(let mode):
            return "wrapped sandbox key permissions are too broad: \(String(mode, radix: 8))"
        case .unsafeOwner(let owner):
            return "wrapped sandbox key has unexpected owner \(owner)"
        case .io(let message):
            return "wrapped sandbox key I/O failed: \(message)"
        }
    }
}

public struct SandboxArtifactKeyStore: Sendable {
    private static let schemaVersion: UInt16 = 1
    private static let algorithm = "P256-ECIES-X963-SHA256-AESGCM"
    private static let payloadMagic = Data("DBSBKEY1".utf8)
    private static let maximumEnvelopeBytes = 64 * 1_024

    private let enclaveKey: SandboxSecureEnclaveKey

    public init(enclaveKey: SandboxSecureEnclaveKey) {
        self.enclaveKey = enclaveKey
    }

    public func create(
        at destination: URL,
        context: SandboxEncryptionContext,
        createdAt: Date = Date()
    ) throws -> SandboxDataEncryptionKey {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SandboxArtifactKeyStoreError.destinationExists
        }
        let dataEncryptionKey = SandboxDataEncryptionKey.generate()
        let publicKeyDigest = try keyIdentityDigest()
        let payload = Self.makePayload(
            key: dataEncryptionKey,
            contextDigest: context.digest
        )
        let wrapped: Data
        do {
            wrapped = try enclaveKey.wrap(payload)
        } catch {
            throw SandboxArtifactKeyStoreError.authenticationFailed
        }
        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            algorithm: Self.algorithm,
            contextDigest: context.digest,
            keyIdentityDigest: publicKeyDigest,
            wrappedKey: wrapped,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.writeAtomically(
            try encoder.encode(envelope),
            to: destination
        )
        return dataEncryptionKey
    }

    public func load(
        from source: URL,
        context: SandboxEncryptionContext
    ) throws -> SandboxDataEncryptionKey {
        try Self.requireSafeFile(source)
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumEnvelopeBytes + 1) ?? Data()
        } catch {
            throw SandboxArtifactKeyStoreError.io(String(describing: error))
        }
        guard !data.isEmpty, data.count <= Self.maximumEnvelopeBytes else {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw SandboxArtifactKeyStoreError.unsupportedVersion(
                envelope.schemaVersion
            )
        }
        guard envelope.algorithm == Self.algorithm,
              envelope.contextDigest.count == SHA256.Digest.byteCount,
              envelope.keyIdentityDigest.count == SHA256.Digest.byteCount,
              !envelope.wrappedKey.isEmpty
        else {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }
        guard envelope.contextDigest == context.digest else {
            throw SandboxArtifactKeyStoreError.contextMismatch
        }
        guard envelope.keyIdentityDigest == (try keyIdentityDigest()) else {
            throw SandboxArtifactKeyStoreError.keyIdentityMismatch
        }

        let payload: Data
        do {
            payload = try enclaveKey.unwrap(envelope.wrappedKey)
        } catch {
            throw SandboxArtifactKeyStoreError.authenticationFailed
        }
        return try Self.parsePayload(
            payload,
            expectedContextDigest: context.digest
        )
    }

    private func keyIdentityDigest() throws -> Data {
        Data(SHA256.hash(data: try enclaveKey.publicKeyX963))
    }

    private static func makePayload(
        key: SandboxDataEncryptionKey,
        contextDigest: Data
    ) -> Data {
        var payload = payloadMagic
        payload.append(contextDigest)
        payload.append(key.rawRepresentation)
        return payload
    }

    private static func parsePayload(
        _ payload: Data,
        expectedContextDigest: Data
    ) throws -> SandboxDataEncryptionKey {
        let expectedLength = payloadMagic.count
            + SHA256.Digest.byteCount
            + SandboxDataEncryptionKey.byteCount
        guard payload.count == expectedLength,
              payload.prefix(payloadMagic.count) == payloadMagic
        else {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }
        let contextStart = payloadMagic.count
        let contextEnd = contextStart + SHA256.Digest.byteCount
        guard Data(payload[contextStart..<contextEnd]) == expectedContextDigest else {
            throw SandboxArtifactKeyStoreError.contextMismatch
        }
        do {
            return try SandboxDataEncryptionKey(
                rawRepresentation: Data(payload[contextEnd..<payload.count])
            )
        } catch {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }
    }

    private static func requireSafeFile(_ source: URL) throws {
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw SandboxArtifactKeyStoreError.io(String(describing: error))
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SandboxArtifactKeyStoreError.invalidEnvelope
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: source.path
            )
        } catch {
            throw SandboxArtifactKeyStoreError.io(String(describing: error))
        }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            ?? UInt16.max
        guard mode & 0o077 == 0 else {
            throw SandboxArtifactKeyStoreError.unsafePermissions(mode)
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            ?? UInt32.max
        guard owner == geteuid() else {
            throw SandboxArtifactKeyStoreError.unsafeOwner(owner)
        }
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SandboxArtifactKeyStoreError.io(
                "destination directory does not exist"
            )
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SandboxArtifactKeyStoreError.io(
                "failed to create temporary key envelope"
            )
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let typed = error as? SandboxArtifactKeyStoreError {
                throw typed
            }
            throw SandboxArtifactKeyStoreError.io(String(describing: error))
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: UInt16
        let algorithm: String
        let contextDigest: Data
        let keyIdentityDigest: Data
        let wrappedKey: Data
        let createdAt: Date
    }
}

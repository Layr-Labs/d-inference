import CryptoKit
import Darwin
import Foundation
import SandboxCore

public struct SandboxDataEncryptionKey: Sendable {
    public static let byteCount = 32

    private let bytes: Data

    private init(validatedBytes: Data) {
        self.bytes = validatedBytes
    }

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == Self.byteCount else {
            throw SandboxEncryptedFileError.invalidKeyLength(rawRepresentation.count)
        }
        self.bytes = rawRepresentation
    }

    public static func generate() -> SandboxDataEncryptionKey {
        let key = SymmetricKey(size: .bits256)
        return SandboxDataEncryptionKey(
            validatedBytes: key.withUnsafeBytes { Data($0) }
        )
    }

    public var rawRepresentation: Data {
        bytes
    }

    fileprivate var symmetricKey: SymmetricKey {
        SymmetricKey(data: bytes)
    }
}

public struct SandboxEncryptionContext: Equatable, Sendable {
    public let sandboxID: SandboxID
    public let generation: SandboxGeneration
    public let role: SandboxDiskRole

    public init(
        sandboxID: SandboxID,
        generation: SandboxGeneration,
        role: SandboxDiskRole
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.role = role
    }

    var digest: Data {
        var canonical = Data("darkbloom-sandbox-encrypted-file-context-v1".utf8)
        canonical.appendLengthPrefixed(Data(sandboxID.description.utf8))
        canonical.appendUInt64(generation.rawValue)
        canonical.appendLengthPrefixed(Data(role.rawValue.utf8))
        return Data(SHA256.hash(data: canonical))
    }
}

public enum SandboxEncryptedFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidKeyLength(Int)
    case invalidChunkSize(Int)
    case sourceNotRegularFile
    case destinationExists
    case malformedHeader
    case unsupportedVersion(UInt16)
    case contextMismatch
    case authenticationFailed
    case truncated
    case trailingData
    case sourceChanged
    case publicationUncertain(Int32)
    case io(String)

    public var description: String {
        switch self {
        case .invalidKeyLength(let count):
            return "sandbox DEK must be 32 bytes, got \(count)"
        case .invalidChunkSize(let count):
            return "encrypted-file chunk size is outside the supported range: \(count)"
        case .sourceNotRegularFile:
            return "encrypted-file source must be a regular file"
        case .destinationExists:
            return "encrypted-file destination already exists"
        case .malformedHeader:
            return "encrypted-file header is malformed"
        case .unsupportedVersion(let version):
            return "unsupported encrypted-file version \(version)"
        case .contextMismatch:
            return "encrypted-file context does not match sandbox generation and role"
        case .authenticationFailed:
            return "encrypted-file authentication failed"
        case .truncated:
            return "encrypted file is truncated"
        case .trailingData:
            return "encrypted file contains trailing data"
        case .sourceChanged:
            return "source file changed while encryption was in progress"
        case .publicationUncertain(let code):
            return "encrypted-file destination may be committed but not durable: errno \(code)"
        case .io(let message):
            return "encrypted-file I/O failed: \(message)"
        }
    }
}

public struct SandboxEncryptedFileCodec: Sendable {
    public static let defaultChunkSize = 1_048_576
    public static let supportedChunkSize = 65_536...8_388_608

    private static let magic = Data([0x44, 0x42, 0x53, 0x42, 0x45, 0x4E, 0x43, 0x31])
    private static let version: UInt16 = 2
    private static let algorithmAES256GCM: UInt8 = 1
    private static let revisionByteCount = 32
    private static let headerByteCount = 96
    private static let authenticationByteCount = 28

    public let chunkSize: Int

    public init(chunkSize: Int = defaultChunkSize) throws {
        guard Self.supportedChunkSize.contains(chunkSize) else {
            throw SandboxEncryptedFileError.invalidChunkSize(chunkSize)
        }
        self.chunkSize = chunkSize
    }

    public func encrypt(
        source: URL,
        destination: URL,
        key: SandboxDataEncryptionKey,
        context: SandboxEncryptionContext
    ) throws {
        do {
            try SandboxDescriptorIO.withStableSourceAndExclusiveDestination(
                source: source,
                destination: destination
            ) { sourceDescriptor, sourceMetadata, destinationDescriptor in
                let plaintextLength = UInt64(sourceMetadata.st_size)
                let chunkCount = plaintextLength == 0
                    ? 0
                    : ((plaintextLength - 1) / UInt64(chunkSize)) + 1
                let revisionID = SymmetricKey(size: .bits256).withUnsafeBytes {
                    Data($0)
                }
                let header = makeHeader(
                    plaintextLength: plaintextLength,
                    chunkCount: chunkCount,
                    contextDigest: context.digest,
                    revisionID: revisionID
                )
                let headerAuthentication: Data
                do {
                    guard let combined = try AES.GCM.seal(
                        Data(),
                        using: key.symmetricKey,
                        authenticating: header
                    ).combined else {
                        throw SandboxEncryptedFileError.authenticationFailed
                    }
                    headerAuthentication = combined
                } catch {
                    throw SandboxEncryptedFileError.authenticationFailed
                }
                guard headerAuthentication.count == Self.authenticationByteCount else {
                    throw SandboxEncryptedFileError.malformedHeader
                }

                var outputHasher = SHA256()
                try SandboxDescriptorIO.writeAll(header, to: destinationDescriptor)
                outputHasher.update(data: header)
                try SandboxDescriptorIO.writeAll(
                    headerAuthentication,
                    to: destinationDescriptor
                )
                outputHasher.update(data: headerAuthentication)

                var totalRead: UInt64 = 0
                for index in 0..<chunkCount {
                    let remaining = plaintextLength - totalRead
                    let expectedCount = Int(min(UInt64(chunkSize), remaining))
                    let plaintext = try SandboxDescriptorIO.readExactly(
                        expectedCount,
                        from: sourceDescriptor,
                        truncated: SandboxEncryptedFileError.sourceChanged
                    )
                    let aad = chunkAAD(
                        header: header,
                        index: index,
                        plaintextLength: UInt32(expectedCount)
                    )
                    let sealed: Data
                    do {
                        guard let combined = try AES.GCM.seal(
                            plaintext,
                            using: key.symmetricKey,
                            authenticating: aad
                        ).combined else {
                            throw SandboxEncryptedFileError.authenticationFailed
                        }
                        sealed = combined
                    } catch {
                        throw SandboxEncryptedFileError.authenticationFailed
                    }
                    try SandboxDescriptorIO.writeAll(
                        sealed,
                        to: destinationDescriptor
                    )
                    outputHasher.update(data: sealed)
                    totalRead += UInt64(expectedCount)
                }

                guard totalRead == plaintextLength,
                      try SandboxDescriptorIO.readUpTo(
                          1,
                          from: sourceDescriptor
                      ).isEmpty
                else {
                    throw SandboxEncryptedFileError.sourceChanged
                }
                return Data(outputHasher.finalize())
            }
        } catch {
            throw Self.mapDescriptorError(error)
        }
    }

    public func decrypt(
        source: URL,
        destination: URL,
        key: SandboxDataEncryptionKey,
        context: SandboxEncryptionContext
    ) throws {
        do {
            try SandboxDescriptorIO.withStableSourceAndExclusiveDestination(
                source: source,
                destination: destination
            ) { sourceDescriptor, _, destinationDescriptor in
                let header = try SandboxDescriptorIO.readExactly(
                    Self.headerByteCount,
                    from: sourceDescriptor,
                    truncated: SandboxEncryptedFileError.truncated
                )
                let parsed = try parseHeader(header)
                let headerAuthentication = try SandboxDescriptorIO.readExactly(
                    Self.authenticationByteCount,
                    from: sourceDescriptor,
                    truncated: SandboxEncryptedFileError.truncated
                )
                do {
                    let box = try AES.GCM.SealedBox(combined: headerAuthentication)
                    _ = try AES.GCM.open(
                        box,
                        using: key.symmetricKey,
                        authenticating: header
                    )
                } catch {
                    throw SandboxEncryptedFileError.authenticationFailed
                }
                guard parsed.contextDigest == context.digest else {
                    throw SandboxEncryptedFileError.contextMismatch
                }

                var outputHasher = SHA256()
                var totalWritten: UInt64 = 0
                for index in 0..<parsed.chunkCount {
                    let remaining = parsed.plaintextLength - totalWritten
                    let plaintextCount = Int(
                        min(UInt64(parsed.chunkSize), remaining)
                    )
                    let sealedCount = plaintextCount + Self.authenticationByteCount
                    let combined = try SandboxDescriptorIO.readExactly(
                        sealedCount,
                        from: sourceDescriptor,
                        truncated: SandboxEncryptedFileError.truncated
                    )
                    let aad = chunkAAD(
                        header: header,
                        index: index,
                        plaintextLength: UInt32(plaintextCount)
                    )
                    let plaintext: Data
                    do {
                        let box = try AES.GCM.SealedBox(combined: combined)
                        plaintext = try AES.GCM.open(
                            box,
                            using: key.symmetricKey,
                            authenticating: aad
                        )
                    } catch {
                        throw SandboxEncryptedFileError.authenticationFailed
                    }
                    guard plaintext.count == plaintextCount else {
                        throw SandboxEncryptedFileError.authenticationFailed
                    }
                    try SandboxDescriptorIO.writeAll(
                        plaintext,
                        to: destinationDescriptor
                    )
                    outputHasher.update(data: plaintext)
                    totalWritten += UInt64(plaintext.count)
                }

                guard totalWritten == parsed.plaintextLength else {
                    throw SandboxEncryptedFileError.truncated
                }
                guard try SandboxDescriptorIO.readUpTo(
                    1,
                    from: sourceDescriptor
                ).isEmpty else {
                    throw SandboxEncryptedFileError.trailingData
                }
                return Data(outputHasher.finalize())
            }
        } catch {
            throw Self.mapDescriptorError(error)
        }
    }

    private func makeHeader(
        plaintextLength: UInt64,
        chunkCount: UInt64,
        contextDigest: Data,
        revisionID: Data
    ) -> Data {
        precondition(revisionID.count == Self.revisionByteCount)
        var header = Data()
        header.append(Self.magic)
        header.appendUInt16(Self.version)
        header.append(Self.algorithmAES256GCM)
        header.append(0)
        header.appendUInt32(UInt32(chunkSize))
        header.appendUInt64(plaintextLength)
        header.appendUInt64(chunkCount)
        header.append(contextDigest)
        header.append(revisionID)
        precondition(header.count == Self.headerByteCount)
        return header
    }

    private func parseHeader(_ header: Data) throws -> ParsedHeader {
        guard header.count == Self.headerByteCount,
              header.prefix(Self.magic.count) == Self.magic
        else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        var cursor = Self.magic.count
        let version = try header.readUInt16(at: &cursor)
        guard version == Self.version else {
            throw SandboxEncryptedFileError.unsupportedVersion(version)
        }
        guard try header.readUInt8(at: &cursor) == Self.algorithmAES256GCM,
              try header.readUInt8(at: &cursor) == 0
        else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        let encodedChunkSize = Int(try header.readUInt32(at: &cursor))
        guard Self.supportedChunkSize.contains(encodedChunkSize) else {
            throw SandboxEncryptedFileError.invalidChunkSize(encodedChunkSize)
        }
        let plaintextLength = try header.readUInt64(at: &cursor)
        let chunkCount = try header.readUInt64(at: &cursor)
        let expectedChunkCount = plaintextLength == 0
            ? 0
            : ((plaintextLength - 1) / UInt64(encodedChunkSize)) + 1
        guard chunkCount == expectedChunkCount,
              cursor + SHA256.byteCount + Self.revisionByteCount == header.count
        else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        let contextDigest = header[cursor..<(cursor + SHA256.byteCount)]
        cursor += SHA256.byteCount
        let revisionID = header[cursor..<(cursor + Self.revisionByteCount)]
        guard revisionID.contains(where: { $0 != 0 }) else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        return ParsedHeader(
            chunkSize: encodedChunkSize,
            plaintextLength: plaintextLength,
            chunkCount: chunkCount,
            contextDigest: Data(contextDigest)
        )
    }

    private func chunkAAD(
        header: Data,
        index: UInt64,
        plaintextLength: UInt32
    ) -> Data {
        var aad = header
        aad.appendUInt64(index)
        aad.appendUInt32(plaintextLength)
        return aad
    }

    private static func mapDescriptorError(_ error: Error) -> SandboxEncryptedFileError {
        if let error = error as? SandboxEncryptedFileError {
            return error
        }
        guard let error = error as? SandboxDescriptorIOError else {
            return .io(String(describing: error))
        }
        switch error {
        case .sourceNotRegularFile:
            return .sourceNotRegularFile
        case .sourceChanged:
            return .sourceChanged
        case .destinationExists:
            return .destinationExists
        case .unsafeDestination:
            return .io("destination path is unsafe")
        case .publicationUncertain(let code):
            return .publicationUncertain(code)
        case .io(let code):
            return .io("errno \(code)")
        }
    }

    private struct ParsedHeader {
        let chunkSize: Int
        let plaintextLength: UInt64
        let chunkCount: UInt64
        let contextDigest: Data
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        appendUInt32(UInt32(value.count))
        append(value)
    }

    func readUInt8(at cursor: inout Int) throws -> UInt8 {
        guard cursor < count else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        defer { cursor += 1 }
        return self[cursor]
    }

    func readUInt16(at cursor: inout Int) throws -> UInt16 {
        try readInteger(at: &cursor, byteCount: 2, type: UInt16.self)
    }

    func readUInt32(at cursor: inout Int) throws -> UInt32 {
        try readInteger(at: &cursor, byteCount: 4, type: UInt32.self)
    }

    func readUInt64(at cursor: inout Int) throws -> UInt64 {
        try readInteger(at: &cursor, byteCount: 8, type: UInt64.self)
    }

    func readInteger<T: FixedWidthInteger>(
        at cursor: inout Int,
        byteCount: Int,
        type: T.Type
    ) throws -> T {
        guard cursor >= 0, cursor + byteCount <= count else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        var value: T = 0
        for byte in self[cursor..<(cursor + byteCount)] {
            value = (value << 8) | T(byte)
        }
        cursor += byteCount
        return value
    }
}

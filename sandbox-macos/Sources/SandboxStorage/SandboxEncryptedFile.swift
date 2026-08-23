import CryptoKit
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
        case .io(let message):
            return "encrypted-file I/O failed: \(message)"
        }
    }
}

public struct SandboxEncryptedFileCodec: Sendable {
    public static let defaultChunkSize = 1_048_576
    public static let supportedChunkSize = 65_536...8_388_608

    private static let magic = Data([0x44, 0x42, 0x53, 0x42, 0x45, 0x4E, 0x43, 0x31])
    private static let version: UInt16 = 1
    private static let algorithmAES256GCM: UInt8 = 1
    private static let headerByteCount = 64
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
        try requireAbsent(destination)
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true else {
            throw SandboxEncryptedFileError.sourceNotRegularFile
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        let plaintextLength = try sourceHandle.seekToEnd()
        try sourceHandle.seek(toOffset: 0)
        let chunkCount = plaintextLength == 0
            ? 0
            : ((plaintextLength - 1) / UInt64(chunkSize)) + 1
        let header = makeHeader(
            plaintextLength: plaintextLength,
            chunkCount: chunkCount,
            contextDigest: context.digest
        )
        let headerAuthentication: Data
        do {
            headerAuthentication = try AES.GCM.seal(
                Data(),
                using: key.symmetricKey,
                authenticating: header
            ).combined!
        } catch {
            throw SandboxEncryptedFileError.authenticationFailed
        }
        guard headerAuthentication.count == Self.authenticationByteCount else {
            throw SandboxEncryptedFileError.malformedHeader
        }

        try withAtomicDestination(destination) { destinationHandle in
            try destinationHandle.write(contentsOf: header)
            try destinationHandle.write(contentsOf: headerAuthentication)

            var totalRead: UInt64 = 0
            for index in 0..<chunkCount {
                let remaining = plaintextLength - totalRead
                let expectedCount = Int(min(UInt64(chunkSize), remaining))
                let plaintext = try readExactly(expectedCount, from: sourceHandle)
                let aad = chunkAAD(
                    header: header,
                    index: index,
                    plaintextLength: UInt32(expectedCount)
                )
                let sealed: Data
                do {
                    sealed = try AES.GCM.seal(
                        plaintext,
                        using: key.symmetricKey,
                        authenticating: aad
                    ).combined!
                } catch {
                    throw SandboxEncryptedFileError.authenticationFailed
                }
                try destinationHandle.write(contentsOf: sealed)
                totalRead += UInt64(expectedCount)
            }

            guard totalRead == plaintextLength else {
                throw SandboxEncryptedFileError.sourceChanged
            }
            if let extra = try sourceHandle.read(upToCount: 1), !extra.isEmpty {
                throw SandboxEncryptedFileError.sourceChanged
            }
        }
    }

    public func decrypt(
        source: URL,
        destination: URL,
        key: SandboxDataEncryptionKey,
        context: SandboxEncryptionContext
    ) throws {
        try requireAbsent(destination)
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true else {
            throw SandboxEncryptedFileError.sourceNotRegularFile
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }

        let header = try readExactly(Self.headerByteCount, from: sourceHandle)
        let parsed = try parseHeader(header)
        guard parsed.contextDigest == context.digest else {
            throw SandboxEncryptedFileError.contextMismatch
        }
        let headerAuthentication = try readExactly(
            Self.authenticationByteCount,
            from: sourceHandle
        )
        do {
            let box = try AES.GCM.SealedBox(combined: headerAuthentication)
            _ = try AES.GCM.open(box, using: key.symmetricKey, authenticating: header)
        } catch {
            throw SandboxEncryptedFileError.authenticationFailed
        }

        try withAtomicDestination(destination) { destinationHandle in
            var totalWritten: UInt64 = 0
            for index in 0..<parsed.chunkCount {
                let remaining = parsed.plaintextLength - totalWritten
                let plaintextCount = Int(min(UInt64(parsed.chunkSize), remaining))
                let sealedCount = plaintextCount + Self.authenticationByteCount
                let combined = try readExactly(sealedCount, from: sourceHandle)
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
                try destinationHandle.write(contentsOf: plaintext)
                totalWritten += UInt64(plaintext.count)
            }

            guard totalWritten == parsed.plaintextLength else {
                throw SandboxEncryptedFileError.truncated
            }
            if let extra = try sourceHandle.read(upToCount: 1), !extra.isEmpty {
                throw SandboxEncryptedFileError.trailingData
            }
        }
    }

    private func makeHeader(
        plaintextLength: UInt64,
        chunkCount: UInt64,
        contextDigest: Data
    ) -> Data {
        var header = Data()
        header.append(Self.magic)
        header.appendUInt16(Self.version)
        header.append(Self.algorithmAES256GCM)
        header.append(0)
        header.appendUInt32(UInt32(chunkSize))
        header.appendUInt64(plaintextLength)
        header.appendUInt64(chunkCount)
        header.append(contextDigest)
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
              cursor + SHA256.byteCount == header.count
        else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        let contextDigest = header[cursor..<(cursor + SHA256.byteCount)]
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

    private func requireAbsent(_ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw SandboxEncryptedFileError.destinationExists
        }
    }

    private func withAtomicDestination(
        _ destination: URL,
        operation: (FileHandle) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SandboxEncryptedFileError.io("destination directory does not exist")
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SandboxEncryptedFileError.io("failed to create temporary destination")
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try operation(handle)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let typed = error as? SandboxEncryptedFileError {
                throw typed
            }
            throw SandboxEncryptedFileError.io(String(describing: error))
        }
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else {
            throw SandboxEncryptedFileError.malformedHeader
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let next = try handle.read(upToCount: count - result.count) ?? Data()
            guard !next.isEmpty else {
                throw SandboxEncryptedFileError.truncated
            }
            result.append(next)
        }
        return result
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

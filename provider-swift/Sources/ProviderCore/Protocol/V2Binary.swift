import Foundation
import Sodium

public let v2BinaryHeaderLength = 192
public let maximumV2CiphertextLength = 16 * 1024 * 1024
public let maximumV2BinaryFrameLength = v2BinaryHeaderLength + maximumV2CiphertextLength

public enum V2BinaryFrameKind: UInt8, Sendable, CaseIterable {
    case preparePayload = 1
    case responseChunk = 2
    case terminalPayload = 3
}

public struct V2BinaryFrameFlags: Sendable, Equatable {
    public static let empty = V2BinaryFrameFlags(unchecked: 0)
    public static let finalFrame = V2BinaryFrameFlags(unchecked: 0x01)
    public static let retransmit = V2BinaryFrameFlags(unchecked: 0x02)
    public static let knownMask: UInt8 = finalFrame.rawValue | retransmit.rawValue

    public let rawValue: UInt8

    public init(rawValue: UInt8) throws {
        let unknown = rawValue & ~Self.knownMask
        guard unknown == 0 else {
            throw V2ProtocolError.unknownFrameFlags(unknown)
        }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public func contains(_ flag: V2BinaryFrameFlags) -> Bool {
        rawValue & flag.rawValue == flag.rawValue
    }

    public static func | (
        lhs: V2BinaryFrameFlags,
        rhs: V2BinaryFrameFlags
    ) -> V2BinaryFrameFlags {
        V2BinaryFrameFlags(unchecked: lhs.rawValue | rhs.rawValue)
    }
}

public enum V2ProtocolError: Error, Sendable, Equatable {
    case truncatedHeader(actual: Int, required: Int)
    case invalidMagic
    case invalidHeaderLength(UInt16)
    case unsupportedMajor(UInt16)
    case unknownFrameKind(UInt8)
    case unknownFrameFlags(UInt8)
    case ciphertextTooLarge(actual: Int, maximum: Int)
    case frameLengthMismatch(actual: Int, expected: Int)
    case ciphertextLengthOverflow(Int)
    case identityMismatch
    case minorVersionMismatch(actual: UInt16, expected: UInt16)
}

public enum V2CryptoError: Error, Sendable, Equatable {
    case protocolError(V2ProtocolError)
    case invalidKeyLength(field: String, actual: Int, expected: Int)
    case truncatedCiphertext
    case authenticationFailed
    case encryptionFailed
    case truncatedFrameBinding
    case frameHeaderBindingMismatch
}

/// The fixed 192-byte, network-byte-order protocol-v2 binary header.
///
/// `cumulativeTokens` is authenticated alongside `rollingDigest`: a receiver
/// can therefore reproduce the rolling chain without inferring token counts
/// from SSE JSON or trusting unauthenticated settlement metadata.
public struct V2BinaryFrameHeader: Sendable, Equatable {
    public static let magic = Data("DBV2".utf8)
    public static let major = protocolV2Major

    public static let magicRange = 0..<4
    public static let kindOffset = 4
    public static let flagsOffset = 5
    public static let headerLengthRange = 6..<8
    public static let majorRange = 8..<10
    public static let minorRange = 10..<12
    public static let providerIDRange = 12..<28
    public static let processGenerationRange = 28..<44
    public static let sessionEpochRange = 44..<52
    public static let requestIDRange = 52..<68
    public static let attemptIDRange = 68..<84
    public static let reservationIDRange = 84..<100
    public static let leaseIDRange = 100..<116
    public static let nonceRange = 116..<140
    public static let rollingDigestRange = 140..<172
    public static let sequenceRange = 172..<180
    public static let ciphertextLengthRange = 180..<184
    public static let cumulativeTokensRange = 184..<192

    public var kind: V2BinaryFrameKind
    public var flags: V2BinaryFrameFlags
    public var minor: UInt16
    public var providerID: ProviderID
    public var providerProcessGeneration: ProviderProcessGenerationID
    public var sessionEpoch: UInt64
    public var requestID: RequestID
    public var attemptID: AttemptID
    public var reservationID: ReservationID
    public var leaseID: LeaseID
    public var nonce: Data
    public var rollingDigest: Data
    public var sequence: UInt64
    public var ciphertextLength: UInt32
    public var cumulativeTokens: UInt64

    public init(
        kind: V2BinaryFrameKind,
        flags: V2BinaryFrameFlags,
        minor: UInt16,
        providerID: ProviderID,
        providerProcessGeneration: ProviderProcessGenerationID,
        sessionEpoch: UInt64,
        requestID: RequestID,
        attemptID: AttemptID,
        reservationID: ReservationID,
        leaseID: LeaseID,
        nonce: Data,
        rollingDigest: Data,
        sequence: UInt64,
        ciphertextLength: UInt32 = 0,
        cumulativeTokens: UInt64 = 0
    ) throws {
        guard nonce.count == 24 else {
            throw V2CryptoError.invalidKeyLength(field: "nonce", actual: nonce.count, expected: 24)
        }
        guard rollingDigest.count == 32 else {
            throw V2CryptoError.invalidKeyLength(
                field: "rolling_digest", actual: rollingDigest.count, expected: 32)
        }
        self.kind = kind
        self.flags = flags
        self.minor = minor
        self.providerID = providerID
        self.providerProcessGeneration = providerProcessGeneration
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID
        self.attemptID = attemptID
        self.reservationID = reservationID
        self.leaseID = leaseID
        self.nonce = nonce
        self.rollingDigest = rollingDigest
        self.sequence = sequence
        self.ciphertextLength = ciphertextLength
        self.cumulativeTokens = cumulativeTokens
    }

    public var attemptIdentity: AttemptIdentity {
        AttemptIdentity(
            providerID: providerID,
            providerProcessGeneration: providerProcessGeneration,
            sessionEpoch: sessionEpoch,
            requestID: requestID,
            attemptID: attemptID,
            reservationID: reservationID,
            leaseID: leaseID
        )
    }

    public func validateIdentity(_ expected: AttemptIdentity) throws {
        guard attemptIdentity == expected else {
            throw V2ProtocolError.identityMismatch
        }
    }

    public func validateSession(
        _ expected: ProviderSessionIdentity,
        negotiatedMinor: UInt16
    ) throws {
        guard attemptIdentity.belongs(to: expected) else {
            throw V2ProtocolError.identityMismatch
        }
        guard minor == negotiatedMinor else {
            throw V2ProtocolError.minorVersionMismatch(actual: minor, expected: negotiatedMinor)
        }
    }

    public func encode() throws -> Data {
        try Self.validateCiphertextLength(Int(ciphertextLength))
        guard nonce.count == 24 else {
            throw V2CryptoError.invalidKeyLength(field: "nonce", actual: nonce.count, expected: 24)
        }
        guard rollingDigest.count == 32 else {
            throw V2CryptoError.invalidKeyLength(
                field: "rolling_digest", actual: rollingDigest.count, expected: 32)
        }

        var output = Data(repeating: 0, count: v2BinaryHeaderLength)
        output.replaceSubrange(Self.magicRange, with: Self.magic)
        output[Self.kindOffset] = kind.rawValue
        output[Self.flagsOffset] = flags.rawValue
        output.writeNetwork(UInt16(v2BinaryHeaderLength), at: Self.headerLengthRange)
        output.writeNetwork(Self.major, at: Self.majorRange)
        output.writeNetwork(minor, at: Self.minorRange)
        output.replaceSubrange(Self.providerIDRange, with: providerID.bytes)
        output.replaceSubrange(
            Self.processGenerationRange, with: providerProcessGeneration.bytes)
        output.writeNetwork(sessionEpoch, at: Self.sessionEpochRange)
        output.replaceSubrange(Self.requestIDRange, with: requestID.bytes)
        output.replaceSubrange(Self.attemptIDRange, with: attemptID.bytes)
        output.replaceSubrange(Self.reservationIDRange, with: reservationID.bytes)
        output.replaceSubrange(Self.leaseIDRange, with: leaseID.bytes)
        output.replaceSubrange(Self.nonceRange, with: nonce)
        output.replaceSubrange(Self.rollingDigestRange, with: rollingDigest)
        output.writeNetwork(sequence, at: Self.sequenceRange)
        output.writeNetwork(ciphertextLength, at: Self.ciphertextLengthRange)
        output.writeNetwork(cumulativeTokens, at: Self.cumulativeTokensRange)
        return output
    }

    /// Validates fixed fields before consulting the attacker-controlled payload.
    public static func decode(_ input: Data) throws -> V2BinaryFrameHeader {
        guard input.count >= v2BinaryHeaderLength else {
            throw V2ProtocolError.truncatedHeader(
                actual: input.count, required: v2BinaryHeaderLength)
        }
        guard input.subdata(in: magicRange) == magic else {
            throw V2ProtocolError.invalidMagic
        }
        let headerLength: UInt16 = input.readNetwork(at: headerLengthRange)
        guard Int(headerLength) == v2BinaryHeaderLength else {
            throw V2ProtocolError.invalidHeaderLength(headerLength)
        }
        let major: UInt16 = input.readNetwork(at: majorRange)
        guard major == Self.major else {
            throw V2ProtocolError.unsupportedMajor(major)
        }
        guard let kind = V2BinaryFrameKind(rawValue: input[kindOffset]) else {
            throw V2ProtocolError.unknownFrameKind(input[kindOffset])
        }
        let flags = try V2BinaryFrameFlags(rawValue: input[flagsOffset])
        let ciphertextLength: UInt32 = input.readNetwork(at: ciphertextLengthRange)
        try validateCiphertextLength(Int(ciphertextLength))

        return try V2BinaryFrameHeader(
            kind: kind,
            flags: flags,
            minor: input.readNetwork(at: minorRange),
            providerID: ProviderID(bytes: input.subdata(in: providerIDRange))!,
            providerProcessGeneration: ProviderProcessGenerationID(
                bytes: input.subdata(in: processGenerationRange))!,
            sessionEpoch: input.readNetwork(at: sessionEpochRange),
            requestID: RequestID(bytes: input.subdata(in: requestIDRange))!,
            attemptID: AttemptID(bytes: input.subdata(in: attemptIDRange))!,
            reservationID: ReservationID(bytes: input.subdata(in: reservationIDRange))!,
            leaseID: LeaseID(bytes: input.subdata(in: leaseIDRange))!,
            nonce: input.subdata(in: nonceRange),
            rollingDigest: input.subdata(in: rollingDigestRange),
            sequence: input.readNetwork(at: sequenceRange),
            ciphertextLength: ciphertextLength,
            cumulativeTokens: input.readNetwork(at: cumulativeTokensRange)
        )
    }

    fileprivate static func validateCiphertextLength(_ length: Int) throws {
        guard length <= maximumV2CiphertextLength else {
            throw V2ProtocolError.ciphertextTooLarge(
                actual: length, maximum: maximumV2CiphertextLength)
        }
    }
}

public struct V2BinaryFrame: Sendable, Equatable {
    public var header: V2BinaryFrameHeader
    public var ciphertext: Data

    public init(header: V2BinaryFrameHeader, ciphertext: Data) {
        self.header = header
        self.ciphertext = ciphertext
    }

    public static func decode(_ input: Data) throws -> V2BinaryFrame {
        let header = try V2BinaryFrameHeader.decode(input)
        let ciphertextLength = Int(header.ciphertextLength)
        let (expected, overflow) = v2BinaryHeaderLength.addingReportingOverflow(ciphertextLength)
        guard !overflow else {
            throw V2ProtocolError.ciphertextLengthOverflow(ciphertextLength)
        }
        guard input.count == expected else {
            throw V2ProtocolError.frameLengthMismatch(actual: input.count, expected: expected)
        }
        return V2BinaryFrame(
            header: header,
            ciphertext: input.subdata(in: v2BinaryHeaderLength..<expected)
        )
    }

    public func encode() throws -> Data {
        guard ciphertext.count <= maximumV2CiphertextLength else {
            throw V2ProtocolError.ciphertextTooLarge(
                actual: ciphertext.count, maximum: maximumV2CiphertextLength)
        }
        guard Int(header.ciphertextLength) == ciphertext.count else {
            throw V2ProtocolError.frameLengthMismatch(
                actual: ciphertext.count, expected: Int(header.ciphertextLength))
        }
        var output = try header.encode()
        output.reserveCapacity(v2BinaryHeaderLength + ciphertext.count)
        output.append(ciphertext)
        return output
    }
}

public struct V2OpenedFrame: Sendable, Equatable {
    public var header: V2BinaryFrameHeader
    public var plaintext: Data
}

public enum V2FrameCrypto {
    /// Exact domain separator used by the committed Rust protocol.
    public static let bindingDomain = Data("darkbloom.protocol.v2.bound-frame\0".utf8)
    public static let keyLength = 32
    public static let nonceLength = 24
    public static let authenticatorLength = 16

    public static func seal(
        senderPrivateKey: Data,
        recipientPublicKey: Data,
        header: V2BinaryFrameHeader,
        plaintext: Data
    ) throws -> Data {
        try validateKey(senderPrivateKey, field: "sender_private_key")
        try validateKey(recipientPublicKey, field: "recipient_public_key")

        let (withHeader, overflow1) = bindingDomain.count.addingReportingOverflow(
            v2BinaryHeaderLength)
        let (boundLength, overflow2) = withHeader.addingReportingOverflow(plaintext.count)
        let (ciphertextLength, overflow3) = boundLength.addingReportingOverflow(
            authenticatorLength)
        guard !overflow1, !overflow2, !overflow3 else {
            throw V2CryptoError.protocolError(.ciphertextLengthOverflow(plaintext.count))
        }
        guard ciphertextLength <= maximumV2CiphertextLength else {
            throw V2CryptoError.protocolError(
                .ciphertextTooLarge(
                    actual: ciphertextLength,
                    maximum: maximumV2CiphertextLength
                ))
        }

        var finalHeader = header
        finalHeader.ciphertextLength = UInt32(ciphertextLength)
        let encodedHeader: Data
        do {
            encodedHeader = try finalHeader.encode()
        } catch let error as V2ProtocolError {
            throw V2CryptoError.protocolError(error)
        }

        var bound = Data()
        bound.reserveCapacity(boundLength)
        bound.append(bindingDomain)
        bound.append(encodedHeader)
        bound.append(plaintext)
        guard
            let ciphertext = v2Sodium.box.seal(
                message: Bytes(bound),
                recipientPublicKey: Bytes(recipientPublicKey),
                senderSecretKey: Bytes(senderPrivateKey),
                nonce: Bytes(finalHeader.nonce)
            )
        else {
            throw V2CryptoError.encryptionFailed
        }
        guard ciphertext.count == ciphertextLength else {
            throw V2CryptoError.encryptionFailed
        }
        do {
            return try V2BinaryFrame(
                header: finalHeader,
                ciphertext: Data(ciphertext)
            ).encode()
        } catch let error as V2ProtocolError {
            throw V2CryptoError.protocolError(error)
        }
    }

    public static func open(
        recipientPrivateKey: Data,
        senderPublicKey: Data,
        wire: Data
    ) throws -> V2OpenedFrame {
        try validateKey(recipientPrivateKey, field: "recipient_private_key")
        try validateKey(senderPublicKey, field: "sender_public_key")

        let frame: V2BinaryFrame
        do {
            frame = try V2BinaryFrame.decode(wire)
        } catch let error as V2ProtocolError {
            throw V2CryptoError.protocolError(error)
        }
        guard frame.ciphertext.count >= authenticatorLength else {
            throw V2CryptoError.truncatedCiphertext
        }
        guard
            let opened = v2Sodium.box.open(
                authenticatedCipherText: Bytes(frame.ciphertext),
                senderPublicKey: Bytes(senderPublicKey),
                recipientSecretKey: Bytes(recipientPrivateKey),
                nonce: Bytes(frame.header.nonce)
            )
        else {
            throw V2CryptoError.authenticationFailed
        }

        let bound = Data(opened)
        let bindingLength = bindingDomain.count + v2BinaryHeaderLength
        guard bound.count >= bindingLength else {
            throw V2CryptoError.truncatedFrameBinding
        }
        guard Data(bound.prefix(bindingDomain.count)) == bindingDomain,
            bound.subdata(in: bindingDomain.count..<bindingLength)
                == wire.subdata(in: 0..<v2BinaryHeaderLength)
        else {
            throw V2CryptoError.frameHeaderBindingMismatch
        }
        return V2OpenedFrame(
            header: frame.header,
            plaintext: bound.subdata(in: bindingLength..<bound.count)
        )
    }

    private static func validateKey(_ key: Data, field: String) throws {
        guard key.count == keyLength else {
            throw V2CryptoError.invalidKeyLength(
                field: field, actual: key.count, expected: keyLength)
        }
    }
}

private nonisolated(unsafe) let v2Sodium = Sodium()

extension Data {
    fileprivate mutating func writeNetwork<T: FixedWidthInteger>(_ value: T, at range: Range<Int>) {
        let bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: bigEndian) { bytes in
            replaceSubrange(range, with: bytes)
        }
    }

    fileprivate func readNetwork<T: FixedWidthInteger>(at range: Range<Int>) -> T {
        var value: T = 0
        for byte in self[range] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}

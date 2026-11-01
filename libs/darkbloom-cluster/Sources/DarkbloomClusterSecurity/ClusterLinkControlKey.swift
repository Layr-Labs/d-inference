import CryptoKit
import Darwin
import Foundation

/// Closed, payload-free failures. Never include key bytes or secrets.
public enum ClusterLinkControlKeyError: Error, Equatable, Sendable {
    case invalidSecret, invalidKey, invalidContext, unreadableSecret
}

/// Which end of one link edge computes a handshake tag. The listener is the
/// end that accepted the TCP connection; the connector dialled it.
public enum ClusterLinkControlRole: UInt8, Sendable, Equatable {
    case listener = 0
    case connector = 1
}

/// Long-term key of one link edge (two members over one cable). The value
/// never leaves this module: callers get handshake tags, tag verification and
/// fresh per-connection directional keys, nothing that re-creates the edge key.
///
/// Production derives it from the native X25519 agreement with its own label
/// (`ClusterNativeKeyDerivation.swift`), so it is bound to the membership
/// transcript and independent of the RDMA record keys. Local qualification
/// derives it from a random secret handed over a pipe or standard input,
/// bound to the epoch and edge; a secret never travels on a command line.
public struct ClusterLinkControlKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let minimumSecretBytes = 32
    public static let maximumSecretBytes = 1024
    private static let keyDomain = Data("darkbloom/link-control/key/v1\0".utf8)
    private static let qualificationDomain = Data("darkbloom/link-control/qualification-secret/v1\0".utf8)
    private static let sessionDomain = Data("darkbloom/link-control/session/v1\0".utf8)
    private static let listenerTagDomain = Data("darkbloom/link-control/handshake/listener/v1\0".utf8)
    private static let connectorTagDomain = Data("darkbloom/link-control/handshake/connector/v1\0".utf8)

    private let authentication: SymmetricKey
    private let sessionBase: SymmetricKey

    public var description: String { "ClusterLinkControlKey(redacted)" }
    public var debugDescription: String { description }

    private init(master: SymmetricKey) {
        authentication = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Self.keyDomain,
            info: Data("handshake-authentication".utf8), outputByteCount: 32)
        sessionBase = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Self.keyDomain,
            info: Data("session-base".utf8), outputByteCount: 32)
    }

    /// Production: the native agreement (canonical public key, all-zero shared
    /// secret refused, HKDF-SHA256 salted with the 32-byte transcript digest)
    /// under the link-control label.
    public static func nativeDerived(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                                     transcriptSHA256: Data) throws -> ClusterLinkControlKey {
        do {
            return .init(master: try NativeTrafficKeyDerivation.deriveLinkControl(privateKey: privateKey,
                peerPublicKey: peerPublicKey, transcriptSHA256: transcriptSHA256))
        } catch { throw ClusterLinkControlKeyError.invalidKey }
    }

    /// Local qualification only: a random secret of 32...1024 bytes, bound to
    /// the epoch and the edge, so the same secret with another epoch or edge
    /// yields another key.
    public static func qualification(secret: Data, epoch: UUID, edgeID: UUID) throws -> ClusterLinkControlKey {
        guard (minimumSecretBytes...maximumSecretBytes).contains(secret.count),
              !secret.allSatisfy({ $0 == 0 }) else { throw ClusterLinkControlKeyError.invalidSecret }
        guard !clusterRecordUUIDBytes(epoch).allSatisfy({ $0 == 0 }),
              !clusterRecordUUIDBytes(edgeID).allSatisfy({ $0 == 0 }) else {
            throw ClusterLinkControlKeyError.invalidContext
        }
        var info = clusterRecordUUIDBytes(epoch); info.append(clusterRecordUUIDBytes(edgeID))
        let master = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: qualificationDomain, info: info, outputByteCount: 32)
        return .init(master: master)
    }

    /// Reads one line of hexadecimal secret (64...2048 digits) from a pipe or
    /// standard input. At most 2,050 bytes are read; the line is never echoed.
    public static func readQualificationSecret(fromDescriptor descriptor: Int32) throws -> Data {
        var digits = [UInt8]()
        digits.reserveCapacity(128)
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ClusterLinkControlKeyError.unreadableSecret }
            if count == 0 || byte == UInt8(ascii: "\n") { break }
            if byte == UInt8(ascii: "\r") { continue }
            guard digits.count < 2 * maximumSecretBytes else { throw ClusterLinkControlKeyError.invalidSecret }
            digits.append(byte)
        }
        return try decodeHexSecret(digits)
    }

    static func decodeHexSecret(_ digits: [UInt8]) throws -> Data {
        guard digits.count % 2 == 0, (2 * minimumSecretBytes...2 * maximumSecretBytes).contains(digits.count) else {
            throw ClusterLinkControlKeyError.invalidSecret
        }
        func nibble(_ value: UInt8) throws -> UInt8 {
            switch value {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return value - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return value - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return value - UInt8(ascii: "A") + 10
            default: throw ClusterLinkControlKeyError.invalidSecret
            }
        }
        var result = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            result.append(try nibble(digits[index]) << 4 | nibble(digits[index + 1]))
            index += 2
        }
        return result
    }

    /// HMAC-SHA256 over a role-specific domain and the caller's handshake bytes.
    public func handshakeTag(role: ClusterLinkControlRole, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Self.tagMessage(role: role, transcript: transcript),
            using: authentication))
    }

    /// Constant-time verification of a peer's handshake tag.
    public func isValidHandshakeTag(_ tag: Data, role: ClusterLinkControlRole, transcript: Data) -> Bool {
        tag.count == 32 && HMAC<SHA256>.isValidAuthenticationCode(tag,
            authenticating: Self.tagMessage(role: role, transcript: transcript), using: authentication)
    }

    /// Fresh keys for one TCP connection: each depends on both handshake nonces
    /// through the transcript digest, the epoch and the edge, and each serves
    /// one direction only.
    public func sessionKeys(transcriptSHA256: Data, epoch: UUID, edgeID: UUID) throws
        -> (connectorToListener: SymmetricKey, listenerToConnector: SymmetricKey) {
        guard transcriptSHA256.count == 32 else { throw ClusterLinkControlKeyError.invalidContext }
        var info = Self.sessionDomain
        info.append(clusterRecordUUIDBytes(epoch)); info.append(clusterRecordUUIDBytes(edgeID))
        let session = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionBase, salt: transcriptSHA256,
            info: info, outputByteCount: 32)
        func direction(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: session, salt: Self.sessionDomain,
                info: Data(label.utf8), outputByteCount: 32)
        }
        return (direction("connector-to-listener"), direction("listener-to-connector"))
    }

    private static func tagMessage(role: ClusterLinkControlRole, transcript: Data) -> Data {
        var message = role == .listener ? listenerTagDomain : connectorTagDomain
        message.append(transcript)
        return message
    }
}

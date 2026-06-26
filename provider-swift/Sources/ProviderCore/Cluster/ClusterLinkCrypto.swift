/// ClusterLinkCrypto -- the data-plane cipher for the inter-node activation link.
///
/// After two cluster members complete the `ClusterHandshake`, they share a
/// 32-byte master secret derived from an ephemeral X25519 agreement. This type
/// turns that secret into two *directional* session keys and seals/opens each
/// activation tensor that crosses the link.
///
/// Design (see docs/architecture/cluster-node-handshake.md §5-6):
///   - Per direction, ChaCha20-Poly1305 under a cached key + a strictly
///     monotonic 96-bit counter nonce. We do NOT do a fresh key agreement per
///     token -- that would cost an ECDH per token; the whole point of the
///     handshake is to amortize the agreement once.
///   - The AEAD's additional authenticated data binds each frame to its
///     cluster, request, layer boundary, and sequence number, so a sealed
///     activation cannot be replayed into a different request/layer or reordered.
///   - Nonce discipline: the counter must never repeat for a given key. A
///     `SealingChannel` enforces monotonicity and refuses to wrap.
///
/// Pure CryptoKit + Foundation: unit-testable on one machine.

import CryptoKit
import Foundation

public enum ClusterLinkError: Error, Equatable, Sendable {
    case nonceCounterExhausted
    case openFailed
    case shortFrame
}

/// Identifies one directed activation frame for AEAD binding.
public struct ClusterFrameContext: Equatable, Sendable {
    public let clusterId: String
    public let requestId: String
    /// Inclusive-exclusive layer interval the sender owns, e.g. "0..24".
    public let layerRange: String
    /// Per-(request,direction) monotonic frame sequence number.
    public let seq: UInt64

    public init(clusterId: String, requestId: String, layerRange: String, seq: UInt64) {
        self.clusterId = clusterId
        self.requestId = requestId
        self.layerRange = layerRange
        self.seq = seq
    }

    /// Deterministic AAD bytes. Field-tagged + length-free safe because each
    /// component is separated by a byte that cannot appear in the others'
    /// canonical forms (`\u{1f}` unit separator), and `seq` is fixed-width.
    public var aad: Data {
        var d = Data()
        d.append(Data(clusterId.utf8))
        d.append(0x1f)
        d.append(Data(requestId.utf8))
        d.append(0x1f)
        d.append(Data(layerRange.utf8))
        d.append(0x1f)
        var s = seq.bigEndian
        withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
        return d
    }
}

/// Derives directional session keys from the handshake master secret.
public enum ClusterSessionKeys {
    /// Domain separator for the link cipher.
    static let info = Data("darkbloom-cluster-link-v1".utf8)

    /// Split the master secret into a (send, recv) key pair for a node.
    ///
    /// Directional keys are derived by binding the HKDF `info` to an ordered
    /// pair of node ids: the key for traffic A→B uses "A>B", B→A uses "B>A".
    /// Both nodes compute both keys identically; each uses the one matching its
    /// send/recv direction. This guarantees the two directions never share a
    /// (key, nonce) space even though both start their counters at 0.
    public static func directionalKey(
        masterSecret: SymmetricKey,
        clusterId: String,
        fromNodeId: String,
        toNodeId: String
    ) -> SymmetricKey {
        var perDirectionInfo = info
        perDirectionInfo.append(Data("|\(clusterId)|\(fromNodeId)>\(toNodeId)".utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterSecret,
            info: perDirectionInfo,
            outputByteCount: 32
        )
    }
}

/// A one-directional sealing channel: cached key + monotonic counter nonce.
/// Not thread-safe by itself; the engine serializes sends per direction.
public final class ClusterSealingChannel {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Build a 96-bit nonce from the 64-bit counter (high 32 bits zero).
    /// Big-endian so it reads as a clean incrementing value on the wire.
    private static func nonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { raw in
            // place the 8 counter bytes in the low end (offsets 4..12)
            for i in 0..<8 { bytes[4 + i] = raw[i] }
        }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// Seal one activation frame. The returned bytes are the combined
    /// ChaChaPoly box (nonce || ciphertext || tag). The frame's `seq` in the
    /// context should match the channel counter for end-to-end ordering checks.
    public func seal(_ plaintext: Data, context: ClusterFrameContext) throws -> Data {
        guard counter != UInt64.max else {
            throw ClusterLinkError.nonceCounterExhausted
        }
        let nonce = try Self.nonce(for: counter)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: context.aad)
        counter += 1
        return box.combined
    }
}

/// A one-directional opening channel: cached key + expected counter.
public final class ClusterOpeningChannel {
    private let key: SymmetricKey
    private var expectedCounter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Open one activation frame, enforcing in-order delivery (the ring link is
    /// a single ordered stream per direction). AAD must reconstruct exactly or
    /// the open fails.
    public func open(_ combined: Data, context: ClusterFrameContext) throws -> Data {
        guard counterMatches(context.seq) else {
            throw ClusterLinkError.openFailed
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw ClusterLinkError.shortFrame
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: context.aad)
        } catch {
            throw ClusterLinkError.openFailed
        }
        expectedCounter += 1
        return plaintext
    }

    private func counterMatches(_ seq: UInt64) -> Bool { seq == expectedCounter }
}

import CryptoKit
import Foundation

/// A bounded, fail-closed two-rank record codec. This is not peer authentication,
/// a transport, a deadline, a native state owner, or a memory admission grant.
/// The caller must supply a fresh 256-bit secret for this authenticated epoch and
/// must never construct another sending channel for the same key/binding/rank.
/// No reset, plaintext fallback or model callback is provided.
public final class ClusterAuthenticatedRecordChannel: @unchecked Sendable {
    public static let framingPrefixBytes = ClusterRecordHeader.byteCount
    public static let tagBytes = ClusterRecordHeader.tagByteCount
    public let limits: ClusterRecordLimits
    private let state: ClusterRecordState

    public init(sessionKey: SymmetricKey, binding: ClusterRecordBinding,
                localRank: Int, limits: ClusterRecordLimits) throws {
        self.limits = limits
        state = try ClusterRecordState(sessionKey: sessionKey, binding: binding,
            localRank: localRank, limits: limits)
    }

    public var status: ClusterRecordStatus { state.status }
    public var maximumSealedRecordBytes: Int {
        Self.framingPrefixBytes + limits.maximumPlaintextBytes + Self.tagBytes
    }

    /// Immediate lock-only invalidation. An operation already inside CryptoKit
    /// finishes locally, then refuses publication if invalidation won the lock.
    /// Caller cancellation/fencing must not wait for crypto or this codec's ARC.
    public func invalidate() { state.invalidate() }

    /// Cap-only, UNAUTHENTICATED framing observation for a bounded RDMA receive.
    /// It neither identifies a peer nor permits state consumption. Receive exactly
    /// this bounded total, then call open with locally expected context. On any
    /// framing/transport failure the caller must invalidate and fence the session.
    public static func boundedRecordByteCount(fromPrefix prefix: Data,
                                              maximumPlaintextBytes: Int) throws -> Int {
        try ClusterRecordHeader.decode(prefix, maximumPlaintextBytes: maximumPlaintextBytes).recordByteCount
    }

    public func seal(_ plaintext: Data, context: ClusterRecordContext) throws -> Data {
        var work: ClusterRecordState.Work?
        do {
            let current = try state.beginSeal(byteCount: plaintext.count, context: context)
            work = current
            let nonce = try AES.GCM.Nonce(data: current.header.nonceBytes)
            let sealed = try AES.GCM.seal(plaintext, using: current.key, nonce: nonce,
                authenticating: current.authenticatedData)
            guard sealed.ciphertext.count == plaintext.count, sealed.tag.count == Self.tagBytes else {
                throw ClusterRecordError.encryptionFailed
            }
            var record = current.header.encoded
            record.append(sealed.ciphertext); record.append(sealed.tag)
            try state.finish(current)
            return record
        } catch {
            state.fail(operation: work?.id)
            throw (error as? ClusterRecordError) ?? .encryptionFailed
        }
    }

    /// finish is the publication linearization point, after AEAD verification.
    /// Invalidation can follow finish before the caller receives the returned Data. The caller must still enforce its unchanged
    /// request deadline and payload/shape/frontier invariants before consumption.
    public func open(_ record: Data, expecting context: ClusterRecordContext) throws -> Data {
        var work: ClusterRecordState.Work?
        do {
            guard record.count >= Self.framingPrefixBytes + Self.tagBytes + 1,
                  record.count <= maximumSealedRecordBytes else {
                throw ClusterRecordError.recordTooLarge
            }
            let header = try ClusterRecordHeader.decode(Data(record.prefix(Self.framingPrefixBytes)),
                maximumPlaintextBytes: limits.maximumPlaintextBytes)
            let current = try state.beginOpen(header: header, recordByteCount: record.count, context: context)
            work = current
            let nonce = try AES.GCM.Nonce(data: header.nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce,
                ciphertext: Data(record.dropFirst(Self.framingPrefixBytes).dropLast(Self.tagBytes)),
                tag: Data(record.suffix(Self.tagBytes)))
            let plaintext = try AES.GCM.open(box, using: current.key, authenticating: current.authenticatedData)
            guard plaintext.count == header.plaintextBytes else { throw ClusterRecordError.authenticationFailed }
            try state.finish(current)
            return plaintext
        } catch {
            state.fail(operation: work?.id)
            throw (error as? ClusterRecordError) ?? .authenticationFailed
        }
    }
}

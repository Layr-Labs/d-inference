import Cmlx
import CryptoKit
import Foundation

extension QwenTensorParallelSealCodec {
    /// The product's codec: the direction keys the pinned data-plane exchange
    /// (S16) derived for this session and load agreement
    /// (`ClusterDataPlaneKeyExchange.tensorParallelSealKeys`), taken once from
    /// the collective; `scope` is the load agreement. Refused on a collective
    /// whose data plane was not keyed for tensor parallel.
    static func product(collective: Collective, scope: Data,
                        rekey: (records: Int, bytes: Int) = (262_144, 2 << 30)) throws -> QwenTensorParallelSealCodec {
        guard let keys = collective.takeTensorParallelSealKeys(), collective.size == 2, !scope.isEmpty else {
            throw ProbeError("Sealed all-sum: the data plane holds no tensor-parallel keys for this session")
        }
        return QwenTensorParallelSealCodec(rank: collective.rank, sendKey: keys.send, receiveKey: keys.receive, scope: scope,
            rekeyFrames: UInt64(max(1, rekey.records)), rekeyBytes: UInt64(max(1, rekey.bytes)))
    }

    /// Bench keys from an ephemeral P-256 agreement over `group` (public keys
    /// exchanged as integers through the group's plain reduction); HKDF-SHA256
    /// with `scope` as salt gives one key per direction.
    public static func bench(group: QwenTensorParallelGroup, scope: Data) throws -> QwenTensorParallelSealCodec {
        let mine = P256.KeyAgreement.PrivateKey()
        let publicBytes = [UInt8](mine.publicKey.x963Representation)
        guard publicBytes.count == 65, group.size == 2 else { throw ProbeError("Sealed bench: unexpected key or group size") }
        var slots = [Int32](repeating: 0, count: 2 * 65)
        for (index, byte) in publicBytes.enumerated() { slots[group.rank * 65 + index] = Int32(byte) }
        let all = try group.exchangeIntegers(slots)
        let peerBytes = Data(all[((1 - group.rank) * 65)..<((1 - group.rank) * 65 + 65)].map { UInt8(clamping: $0) })
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerBytes)
        let secret = try mine.sharedSecretFromKeyAgreement(with: peer)
        func key(_ from: Int) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: scope,
                sharedInfo: Data("darkbloom-tp-sealed-bench-v1|rank\(from)->rank\(1 - from)".utf8), outputByteCount: 32)
        }
        return QwenTensorParallelSealCodec(rank: group.rank, sendKey: key(group.rank), receiveKey: key(1 - group.rank), scope: scope)
    }

    /// Installs this codec for the process's sealed all-sums (one at a time):
    /// streamed pieces on a JACCL mesh, whole frames on other groups.
    public func install() throws {
        let context = Unmanaged.passRetained(self).toOpaque()
        let status = mlx_distributed_set_streamed_seal_codec({ context, plaintext, bytes, frame, counter in
            guard let context, let plaintext, let frame else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.seal(plaintext, bytes, frame, counter)
        }, { context, frame, bytes, plaintext, counter, peer in
            guard let context, let frame, let plaintext else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.open(frame, bytes, plaintext, counter, Int(peer))
        }, { context, plaintext, length, sealed, counter, piece, pieces, total in
            guard let context, let plaintext, let sealed else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.sealPiece(plaintext, length, sealed, counter, Int(piece), Int(pieces), total)
        }, { context, sealed, length, plaintext, counter, piece, pieces, total, peer in
            guard let context, let sealed, let plaintext else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.openPiece(sealed, length, plaintext, counter, Int(piece), Int(pieces), total, Int(peer))
        }, context, Self.frameOverhead, Self.streamedPieceBytes)
        guard status == 0 else {
            Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).release()
            throw ProbeError("Sealed all-sum: the codec could not be installed")
        }
    }
}

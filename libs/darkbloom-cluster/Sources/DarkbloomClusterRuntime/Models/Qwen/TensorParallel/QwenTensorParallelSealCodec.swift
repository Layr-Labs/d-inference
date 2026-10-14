import Cmlx
import CryptoKit
import Foundation

/// The codec of the sealed all-sum (`mlx_distributed_all_sum_sealed`, the
/// fork's `SealedAllSum`): every partial leaves a rank as one AES-256-GCM
/// frame (ciphertext + 16-byte tag) under that rank's direction key, with a
/// nonce of (sender rank, counter) that never repeats under a key and
/// authenticated data binding the run's scope, the counter and the length.
/// A peer frame that does not open is refused: the evaluation fails, and the
/// codec stays refused (`refused`), so nothing after a tamper is summed.
///
/// Keys: `bench(group:scope:)` derives the two direction keys from an
/// ephemeral, UNAUTHENTICATED P-256 exchange over the rank group: a bench
/// measurement of the sealed path's cost only. The product derives them
/// from the pinned data-plane exchange (S16, `ClusterDataPlaneKeyExchange`)
/// instead; nothing here replaces that trust.
public final class QwenTensorParallelSealCodec: @unchecked Sendable {
    public static let tagBytes = 16
    public let rank: Int
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let scope: Data
    private let lock = NSLock()
    private var refusedFlag = false
    public private(set) var sealedFrames: UInt64 = 0

    public var refused: Bool { lock.lock(); defer { lock.unlock() }; return refusedFlag }
    /// Test only (bench): flip one ciphertext byte of the frame this rank
    /// seals at this counter, to prove the peer refuses it.
    public var tamperAtCounter: UInt64?

    init(rank: Int, sendKey: SymmetricKey, receiveKey: SymmetricKey, scope: Data) {
        self.rank = rank; self.sendKey = sendKey; self.receiveKey = receiveKey; self.scope = scope
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

    private func nonce(sender: Int, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[3] = UInt8(sender)
        for i in 0..<8 { bytes[4 + i] = UInt8((counter >> (8 * UInt64(7 - i))) & 0xFF) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private func aad(counter: UInt64, bytes: Int, sender: Int) -> Data {
        var data = scope
        data.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(bytes).bigEndian) { Array($0) })
        data.append(UInt8(sender))
        return data
    }

    func seal(_ plaintext: UnsafeRawPointer, _ bytes: Int, _ frame: UnsafeMutableRawPointer, _ counter: UInt64) -> Int32 {
        guard !refused else { return 1 }
        do {
            let box = try AES.GCM.seal(UnsafeRawBufferPointer(start: plaintext, count: bytes), using: sendKey,
                nonce: try nonce(sender: rank, counter: counter), authenticating: aad(counter: counter, bytes: bytes, sender: rank))
            guard box.ciphertext.count == bytes, box.tag.count == Self.tagBytes else { return 1 }
            box.ciphertext.copyBytes(to: frame.assumingMemoryBound(to: UInt8.self), count: bytes)
            box.tag.copyBytes(to: (frame + bytes).assumingMemoryBound(to: UInt8.self), count: Self.tagBytes)
            if let tamper = tamperAtCounter, tamper == counter {
                frame.assumingMemoryBound(to: UInt8.self)[bytes / 2] ^= 0x01
                FileHandle.standardError.write(Data("[tp-sealed] TEST: flipped one byte of sealed frame \(counter)\n".utf8))
            }
            lock.lock(); sealedFrames += 1; lock.unlock()
            return 0
        } catch { return 1 }
    }

    func open(_ frame: UnsafeRawPointer, _ bytes: Int, _ plaintext: UnsafeMutableRawPointer, _ counter: UInt64, _ peer: Int) -> Int32 {
        guard !refused, peer == 1 - rank else { return 1 }
        do {
            let box = try AES.GCM.SealedBox(nonce: try nonce(sender: peer, counter: counter),
                ciphertext: Data(bytes: frame, count: bytes), tag: Data(bytes: frame + bytes, count: Self.tagBytes))
            let opened = try AES.GCM.open(box, using: receiveKey, authenticating: aad(counter: counter, bytes: bytes, sender: peer))
            guard opened.count == bytes else { throw ProbeError("length") }
            opened.copyBytes(to: plaintext.assumingMemoryBound(to: UInt8.self), count: bytes)
            return 0
        } catch {
            lock.lock(); refusedFlag = true; lock.unlock()
            FileHandle.standardError.write(Data("[tp-sealed] a peer frame did not authenticate (counter \(counter)): refused\n".utf8))
            return 1
        }
    }

    /// Installs this codec for the process's sealed all-sums (one at a time).
    public func install() throws {
        let context = Unmanaged.passRetained(self).toOpaque()
        let status = mlx_distributed_set_seal_codec({ context, plaintext, bytes, frame, counter in
            guard let context, let plaintext, let frame else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.seal(plaintext, bytes, frame, counter)
        }, { context, frame, bytes, plaintext, counter, peer in
            guard let context, let frame, let plaintext else { return 1 }
            let codec = Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).takeUnretainedValue()
            return codec.open(frame, bytes, plaintext, counter, Int(peer))
        }, context, Self.tagBytes)
        guard status == 0 else {
            Unmanaged<QwenTensorParallelSealCodec>.fromOpaque(context).release()
            throw ProbeError("Sealed all-sum: the codec could not be installed")
        }
    }
}

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

    /// Two codecs with the same keys seen from each side (tests).
    public static func pair(scope: Data) -> (QwenTensorParallelSealCodec, QwenTensorParallelSealCodec) {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        return (QwenTensorParallelSealCodec(rank: 0, sendKey: a, receiveKey: b, scope: scope),
                QwenTensorParallelSealCodec(rank: 1, sendKey: b, receiveKey: a, scope: scope))
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

}

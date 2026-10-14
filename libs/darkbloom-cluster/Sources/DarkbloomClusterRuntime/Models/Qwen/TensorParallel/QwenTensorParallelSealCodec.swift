import CryptoKit
import Foundation

/// The codec of the sealed all-sum (`mlx_distributed_all_sum_sealed`, the
/// fork's `SealedAllSum`): every partial leaves a rank as one AES-256-GCM
/// frame under that rank's direction key (pieces sealed in parallel, each
/// with a nonce of (piece, sender rank, counter) that never repeats under a
/// key and authenticated data binding the run's scope, the counter, the
/// length and the piece).
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

    /// A frame is the partial cut into `chunks(bytes)` pieces sealed in
    /// parallel (prefill partials are megabytes; one AES-GCM pass over 10.5 MB
    /// cost about 2 ms per side per reduction): the pieces' ciphertexts in
    /// order, then one 16-byte tag per piece, then zero padding up to
    /// `frameOverhead`. Each piece has its own nonce (sender, counter, piece).
    public static let maximumChunks = 64
    public static let frameOverhead = maximumChunks * tagBytes
    static let chunkTarget = 256 << 10

    static func chunks(_ bytes: Int) -> Int { max(1, min(maximumChunks, (bytes + chunkTarget - 1) / chunkTarget)) }
    static func piece(_ index: Int, of count: Int, bytes: Int) -> Range<Int> {
        let per = (bytes + count - 1) / count
        return min(bytes, index * per) ..< min(bytes, (index + 1) * per)
    }

    private func nonce(sender: Int, counter: UInt64, piece: Int) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = UInt8(piece >> 8); bytes[1] = UInt8(piece & 0xFF)
        bytes[3] = UInt8(sender)
        for i in 0..<8 { bytes[4 + i] = UInt8((counter >> (8 * UInt64(7 - i))) & 0xFF) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private func aad(counter: UInt64, bytes: Int, sender: Int, piece: Int, of count: Int) -> Data {
        var data = scope
        data.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(bytes).bigEndian) { Array($0) })
        data.append(UInt8(sender))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(piece).bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(count).bigEndian) { Array($0) })
        return data
    }

    /// Runs `body` for every piece, in parallel when there is more than one.
    private func eachPiece(_ count: Int, _ body: (Int) -> Bool) -> Bool {
        if count == 1 { return body(0) }
        let guardLock = NSLock()
        var failed = false
        DispatchQueue.concurrentPerform(iterations: count) { index in
            if !body(index) { guardLock.lock(); failed = true; guardLock.unlock() }
        }
        return !failed
    }

    func seal(_ plaintext: UnsafeRawPointer, _ bytes: Int, _ frame: UnsafeMutableRawPointer, _ counter: UInt64) -> Int32 {
        guard !refused else { return 1 }
        let count = Self.chunks(bytes)
        let out = frame.assumingMemoryBound(to: UInt8.self)
        let ok = eachPiece(count) { index in
            let range = Self.piece(index, of: count, bytes: bytes)
            do {
                let box = try AES.GCM.seal(UnsafeRawBufferPointer(start: plaintext + range.lowerBound, count: range.count),
                    using: sendKey, nonce: try nonce(sender: rank, counter: counter, piece: index),
                    authenticating: aad(counter: counter, bytes: bytes, sender: rank, piece: index, of: count))
                guard box.ciphertext.count == range.count, box.tag.count == Self.tagBytes else { return false }
                box.ciphertext.copyBytes(to: out + range.lowerBound, count: range.count)
                box.tag.copyBytes(to: out + bytes + index * Self.tagBytes, count: Self.tagBytes)
                return true
            } catch { return false }
        }
        guard ok else { return 1 }
        (out + bytes + count * Self.tagBytes).initialize(repeating: 0, count: Self.frameOverhead - count * Self.tagBytes)
        if let tamper = tamperAtCounter, tamper == counter {
            out[bytes / 2] ^= 0x01
            FileHandle.standardError.write(Data("[tp-sealed] TEST: flipped one byte of sealed frame \(counter)\n".utf8))
        }
        lock.lock(); sealedFrames += 1; lock.unlock()
        return 0
    }

    func open(_ frame: UnsafeRawPointer, _ bytes: Int, _ plaintext: UnsafeMutableRawPointer, _ counter: UInt64, _ peer: Int) -> Int32 {
        guard !refused, peer == 1 - rank else { return 1 }
        let count = Self.chunks(bytes)
        let source = frame.assumingMemoryBound(to: UInt8.self)
        let target = plaintext.assumingMemoryBound(to: UInt8.self)
        var padding = true
        for offset in (bytes + count * Self.tagBytes) ..< (bytes + Self.frameOverhead) where source[offset] != 0 { padding = false; break }
        let ok = padding && eachPiece(count) { index in
            let range = Self.piece(index, of: count, bytes: bytes)
            do {
                let box = try AES.GCM.SealedBox(nonce: try nonce(sender: peer, counter: counter, piece: index),
                    ciphertext: Data(bytes: source + range.lowerBound, count: range.count),
                    tag: Data(bytes: source + bytes + index * Self.tagBytes, count: Self.tagBytes))
                let opened = try AES.GCM.open(box, using: receiveKey,
                    authenticating: aad(counter: counter, bytes: bytes, sender: peer, piece: index, of: count))
                guard opened.count == range.count else { return false }
                opened.copyBytes(to: target + range.lowerBound, count: range.count)
                return true
            } catch { return false }
        }
        guard ok else {
            lock.lock(); refusedFlag = true; lock.unlock()
            FileHandle.standardError.write(Data("[tp-sealed] a peer frame did not authenticate (counter \(counter)): refused\n".utf8))
            return 1
        }
        return 0
    }
}

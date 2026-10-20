import CryptoKit
import Foundation

/// The codec of the sealed all-sum (`mlx_distributed_all_sum_sealed`, the
/// fork's `SealedAllSum`): every partial leaves a rank as one AES-256-GCM
/// frame under that rank's direction key (pieces sealed in parallel, each
/// with a nonce of (piece, sender rank, counter) that never repeats under a
/// key and authenticated data binding the run's scope, the counter, the
/// length and the piece). On a JACCL mesh the frame is streamed
/// (`sealPiece`/`openPiece`): each piece carries its own tag, so it is sent
/// when sealed and opened when it lands.
/// A peer frame that does not open is refused: the evaluation fails, and the
/// codec stays refused (`refused`), so nothing after a tamper is summed.
///
/// Keys: the product's (`product(collective:scope:)`) come from the pinned
/// data-plane exchange (S16, `ClusterDataPlaneKeyExchange`) of this session,
/// rekeyed by frame count and bytes. `bench(group:scope:)` derives them from
/// an ephemeral, UNAUTHENTICATED P-256 exchange over the rank group: a bench
/// measurement of the sealed path's cost only, never the product's trust.
public final class QwenTensorParallelSealCodec: @unchecked Sendable {
    public static let tagBytes = 16
    public let rank: Int
    private let baseSendKey: SymmetricKey
    private let baseReceiveKey: SymmetricKey
    private let scope: Data
    /// Rekey: a new key generation (HKDF of the base keys) after this many
    /// frames or bytes per direction (`ClusterRecordRekeyPolicy`'s count and
    /// byte limits). Both ranks seal and open frames of the same sizes in the
    /// same order, so both cross a generation at the same counter. Age is not
    /// a trigger here: two clocks would not agree on the frame.
    public let rekeyFrames: UInt64
    public let rekeyBytes: UInt64
    private var lastCounter = UInt64.max, generation: UInt64 = 0, framesInGeneration: UInt64 = 0, bytesInGeneration: UInt64 = 0
    private var generationKeys: (generation: UInt64, send: SymmetricKey, receive: SymmetricKey)?
    public var keyGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    private let lock = NSLock()
    private var refusedFlag = false
    public private(set) var sealedFrames: UInt64 = 0

    public var refused: Bool { lock.lock(); defer { lock.unlock() }; return refusedFlag }
    /// Test only (bench): flip one ciphertext byte of the frame this rank
    /// seals at this counter, to prove the peer refuses it.
    public var tamperAtCounter: UInt64?

    init(rank: Int, sendKey: SymmetricKey, receiveKey: SymmetricKey, scope: Data,
         rekeyFrames: UInt64 = 262_144, rekeyBytes: UInt64 = 2 << 30) {
        self.rank = rank; baseSendKey = sendKey; baseReceiveKey = receiveKey; self.scope = scope
        self.rekeyFrames = max(1, rekeyFrames); self.rekeyBytes = max(1, rekeyBytes)
    }

    /// The keys of `counter`'s generation. A new counter (a frame not seen
    /// before) counts toward the generation's limits first; counters only grow.
    private func keys(counter: UInt64, bytes: Int) -> (send: SymmetricKey, receive: SymmetricKey)? {
        lock.lock(); defer { lock.unlock() }
        if counter != lastCounter {
            guard lastCounter == .max || counter > lastCounter else { return nil }
            if lastCounter != .max, framesInGeneration >= rekeyFrames || bytesInGeneration + UInt64(bytes) > rekeyBytes {
                generation += 1; framesInGeneration = 0; bytesInGeneration = 0
            }
            lastCounter = counter; framesInGeneration += 1; bytesInGeneration += UInt64(bytes)
        }
        if let cached = generationKeys, cached.generation == generation { return (cached.send, cached.receive) }
        func derive(_ base: SymmetricKey) -> SymmetricKey {
            guard generation > 0 else { return base }
            var info = Data("darkbloom/tensor-parallel-seal/generation/v1\0".utf8)
            info.append(contentsOf: withUnsafeBytes(of: generation.bigEndian) { Array($0) })
            return HKDF<SHA256>.deriveKey(inputKeyMaterial: base, salt: scope, info: info, outputByteCount: 32)
        }
        let value = (generation, derive(baseSendKey), derive(baseReceiveKey))
        generationKeys = value
        return (value.1, value.2)
    }

    /// Two codecs with the same keys seen from each side (tests).
    public static func pair(scope: Data, rekeyFrames: UInt64 = 262_144,
                            rekeyBytes: UInt64 = 2 << 30) -> (QwenTensorParallelSealCodec, QwenTensorParallelSealCodec) {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        return (QwenTensorParallelSealCodec(rank: 0, sendKey: a, receiveKey: b, scope: scope, rekeyFrames: rekeyFrames, rekeyBytes: rekeyBytes),
                QwenTensorParallelSealCodec(rank: 1, sendKey: b, receiveKey: a, scope: scope, rekeyFrames: rekeyFrames, rekeyBytes: rekeyBytes))
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

    /// The streamed frame: pieces of `streamedPieceBytes` plaintext bytes (the
    /// last can be shorter), each its ciphertext then its tag. Sealed, a piece
    /// is 256 KiB, so four fill one 1 MiB RDMA frame.
    public static let streamedPieceBytes = (256 << 10) - tagBytes

    /// True when `length` is piece `piece` of a `total`-byte partial cut into
    /// `count` streamed pieces (both ranks cut it the same way).
    static func isStreamedPiece(_ piece: Int, of count: Int, total: Int, length: Int) -> Bool {
        let size = streamedPieceBytes
        return total >= 0 && count == max(1, (total + size - 1) / size) && count <= 0xFFFF
            && piece >= 0 && piece < count && length == min(size, total - piece * size)
    }

    /// `aad` and the piece size: no streamed piece opens as a whole-frame
    /// piece (the data differ in length), and a rank that cuts other pieces
    /// is refused.
    private func streamedAAD(counter: UInt64, bytes: Int, sender: Int, piece: Int, of count: Int) -> Data {
        var data = aad(counter: counter, bytes: bytes, sender: sender, piece: piece, of: count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(Self.streamedPieceBytes).bigEndian) { Array($0) })
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
        guard !refused, let sendKey = keys(counter: counter, bytes: bytes)?.send else { return 1 }
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
        guard !refused, peer == 1 - rank, let receiveKey = keys(counter: counter, bytes: bytes)?.receive else { return 1 }
        let count = Self.chunks(bytes)
        let source = frame.assumingMemoryBound(to: UInt8.self)
        let target = plaintext.assumingMemoryBound(to: UInt8.self)
        var padding = true
        for offset in (bytes + count * Self.tagBytes) ..< (bytes + Self.frameOverhead) where source[offset] != 0 { padding = false; break }
        let ok = padding && eachPiece(count) { index in
            let range = Self.piece(index, of: count, bytes: bytes)
            do {
                // Views of the received frame: the piece is not first copied out of it.
                let box = try AES.GCM.SealedBox(nonce: try nonce(sender: peer, counter: counter, piece: index),
                    ciphertext: UnsafeRawBufferPointer(start: source + range.lowerBound, count: range.count),
                    tag: UnsafeRawBufferPointer(start: source + bytes + index * Self.tagBytes, count: Self.tagBytes))
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

    /// One streamed piece: `length` plaintext bytes become `length` ciphertext
    /// bytes, then the tag. Any thread, any order within a counter.
    func sealPiece(_ plaintext: UnsafeRawPointer, _ length: Int, _ sealed: UnsafeMutableRawPointer, _ counter: UInt64,
                   _ piece: Int, _ count: Int, _ total: Int) -> Int32 {
        guard !refused, Self.isStreamedPiece(piece, of: count, total: total, length: length),
              let sendKey = keys(counter: counter, bytes: total)?.send else { return 1 }
        do {
            let box = try AES.GCM.seal(UnsafeRawBufferPointer(start: plaintext, count: length), using: sendKey,
                nonce: try nonce(sender: rank, counter: counter, piece: piece),
                authenticating: streamedAAD(counter: counter, bytes: total, sender: rank, piece: piece, of: count))
            guard box.ciphertext.count == length, box.tag.count == Self.tagBytes else { return 1 }
            let out = sealed.assumingMemoryBound(to: UInt8.self)
            box.ciphertext.copyBytes(to: out, count: length)
            box.tag.copyBytes(to: out + length, count: Self.tagBytes)
            if piece == count / 2, let tamper = tamperAtCounter, tamper == counter {
                out[length / 2] ^= 0x01
                FileHandle.standardError.write(Data("[tp-sealed] TEST: flipped one byte of sealed frame \(counter)\n".utf8))
            }
            if piece == 0 { lock.lock(); sealedFrames += 1; lock.unlock() }
            return 0
        } catch { return 1 }
    }

    /// One streamed peer piece: `length` ciphertext bytes and the tag become
    /// `length` plaintext bytes, or a refusal that holds for the session.
    func openPiece(_ sealed: UnsafeRawPointer, _ length: Int, _ plaintext: UnsafeMutableRawPointer, _ counter: UInt64,
                   _ piece: Int, _ count: Int, _ total: Int, _ peer: Int) -> Int32 {
        guard !refused, peer == 1 - rank, Self.isStreamedPiece(piece, of: count, total: total, length: length),
              let receiveKey = keys(counter: counter, bytes: total)?.receive else { return 1 }
        let source = sealed.assumingMemoryBound(to: UInt8.self)
        let opened: Data
        do {
            // Views of the received frame: the piece is not first copied out of it.
            let box = try AES.GCM.SealedBox(nonce: try nonce(sender: peer, counter: counter, piece: piece),
                ciphertext: UnsafeRawBufferPointer(start: source, count: length),
                tag: UnsafeRawBufferPointer(start: source + length, count: Self.tagBytes))
            opened = try AES.GCM.open(box, using: receiveKey,
                authenticating: streamedAAD(counter: counter, bytes: total, sender: peer, piece: piece, of: count))
        } catch { return refuse(counter: counter, piece: piece) }
        guard opened.count == length else { return refuse(counter: counter, piece: piece) }
        opened.copyBytes(to: plaintext.assumingMemoryBound(to: UInt8.self), count: length)
        return 0
    }

    private func refuse(counter: UInt64, piece: Int) -> Int32 {
        lock.lock(); refusedFlag = true; lock.unlock()
        FileHandle.standardError.write(Data(
            "[tp-sealed] a peer piece did not authenticate (counter \(counter), piece \(piece)): refused\n".utf8))
        return 1
    }
}

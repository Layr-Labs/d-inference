// Copyright © 2026 Eigen Labs.
//
// Byte-level BPE pieces shared by Flint's protocol vocabulary and the
// JSON-answer vocabulary: GPT-2 byte decoding, prefix-pruned searches over
// bytewise-ordered pieces, and a per-tokenizer cache.

import Foundation

/// GPT-2 byte-level BPE spelling. Pieces are raw bytes, never independently
/// UTF-8 decoded: a multi-byte character may span tokens while ASCII framing
/// stays exact.
enum ByteLevelBPE {
    private static let byteDecoder: [Unicode.Scalar: UInt8] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); scalars.append(256 + extra); extra += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(scalars, bytes).map {
            (Unicode.Scalar($0.0)!, UInt8($0.1))
        })
    }()

    /// The bytes of one vocabulary entry, or nil outside the byte alphabet.
    static func bytes(_ raw: String) -> [UInt8]? {
        var result = [UInt8]()
        for scalar in raw.unicodeScalars {
            guard let byte = byteDecoder[scalar] else { return nil }
            result.append(byte)
        }
        return result
    }
}

/// A vocabulary whose searchable token pieces are also listed in bytewise
/// order, so automata can prune whole token ranges at their first rejected byte.
protocol ByteOrderedPieceVocabulary: AnyObject {
    var pieces: [[UInt8]] { get }
    /// Searchable token ids sorted bytewise by piece. Every listed piece is
    /// non-empty.
    var byteOrderedTokenIDs: [Int32] { get }
}

extension ByteOrderedPieceVocabulary {
    /// Every searchable token whose complete piece `consume` accepts from
    /// `state`, in ascending token order.
    func acceptedTokens<State>(from state: State, consume: (inout State, UInt8) -> Bool) -> [Int] {
        let pieces = pieces
        let order = byteOrderedTokenIDs
        var accepted: [Int] = []
        Self.collect(pieces, order, 0, order.count, depth: 0, state: state, consume: consume, into: &accepted)
        return accepted.sorted()
    }

    /// Pieces in `lower..<upper` share their first `depth` bytes and are all
    /// longer than `depth`, so their next bytes are sorted.
    private static func collect<State>(_ pieces: [[UInt8]], _ order: [Int32], _ lower: Int, _ upper: Int,
                                       depth: Int, state: State, consume: (inout State, UInt8) -> Bool,
                                       into accepted: inout [Int]) {
        var index = lower
        while index < upper {
            let byte = pieces[Int(order[index])][depth]
            var low = index + 1, high = upper
            while low < high {
                let middle = (low + high) / 2
                if pieces[Int(order[middle])][depth] == byte { low = middle + 1 } else { high = middle }
            }
            let end = low
            var next = state
            if consume(&next, byte) {
                var rest = index
                while rest < end, pieces[Int(order[rest])].count == depth + 1 {
                    accepted.append(Int(order[rest]))
                    rest += 1
                }
                if rest < end {
                    collect(pieces, order, rest, end, depth: depth + 1, state: next, consume: consume, into: &accepted)
                }
            }
            index = end
        }
    }
}

/// Vocabularies keyed by live tokenizer handle, without retaining a retired
/// model. A small LRU bounds idle host memory; active requests own their
/// immutable vocabulary independently of eviction.
final class TokenizerVocabularyCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        weak var owner: TokenizerHandle?
        let key: Key
        let value: Value
    }
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(capacity: Int) { self.capacity = capacity }

    func value(for handle: TokenizerHandle, key: Key, build: () throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.owner == nil }
        if let index = entries.firstIndex(where: { $0.owner === handle && $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.value
        }
        let value = try build()
        if entries.count == capacity { entries.removeFirst() }
        entries.append(.init(owner: handle, key: key, value: value))
        return value
    }
}

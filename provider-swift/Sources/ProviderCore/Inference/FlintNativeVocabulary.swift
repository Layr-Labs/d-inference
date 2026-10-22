// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Byte-level pieces, never independently UTF-8 decoded payload tokens. A
/// multi-byte character may span tokens; ASCII framing still remains exact.
final class FlintNativeVocabulary: Sendable {
    static let markers: [(String, Int)] = [
        ("<|begin_of_text|>", 150000), ("<|end_of_text|>", 150001),
        ("<|system|>", 150002), ("<|user|>", 150003), ("<|assistant|>", 150004),
        ("<|observation|>", 150005), ("<think>", 150006), ("</think>", 150007),
        ("<tool_call>", 150010), ("</tool_call>", 150011),
        ("<arg_key>", 150012), ("</arg_key>", 150013),
        ("<arg_value>", 150014), ("</arg_value>", 150015), ("<|developer|>", 150018),
    ]
    let pieces: [[UInt8]]
    let nonStopTokenIDs: [Int]
    let stopTokenIDs: Set<Int>
    let answerStops: Set<Int>
    let observationStop: Int
    let fallbackTokenID: Int
    let markerCompleters: [Int]
    let keyDelimiters: [Int]
    let jsonSensitive: [Int]
    /// Response-format string bodies: quote, escape, marker close and C0.
    let jsonStringSensitive: [Int]
    /// Non-stop tokens in bytewise piece order, for prefix-pruned searches.
    let byteOrderedTokenIDs: [Int32]
    let byFirstByte: [[Int]]
    private let longestFirst: [Int]

    private static let cache = Cache()

    static func cached(for handle: TokenizerHandle, stopTokenIDs: Set<Int>) throws -> FlintNativeVocabulary {
        try cache.get(handle, stops: stopTokenIDs)
    }

    convenience init(tokenizer: any MLXLMCommon.Tokenizer, stopTokenIDs: Set<Int>) throws {
        for (marker, id) in Self.markers {
            guard tokenizer.convertTokenToId(marker) == id,
                  tokenizer.convertIdToToken(id) == marker,
                  tokenizer.encode(text: marker, addSpecialTokens: false) == [id],
                  tokenizer.decode(tokenIds: [id], skipSpecialTokens: false) == marker else {
                throw ToolConstraintSchemaError.invalid("Flint protocol vocabulary does not match the pinned marker contract")
            }
        }
        guard Set([150001, 150003, 150005, 150018]).isSubset(of: stopTokenIDs),
              stopTokenIDs.allSatisfy({ (0..<150144).contains($0) }) else {
            throw ToolConstraintSchemaError.invalid("Flint protocol requires the artifact EOS set")
        }
        var pieces = [[UInt8]]()
        pieces.reserveCapacity(150144)
        for id in 0..<150144 {
            guard let raw = tokenizer.convertIdToToken(id),
                  let bytes = Self.bytes(raw), !bytes.isEmpty else {
                throw ToolConstraintSchemaError.invalid("Incomplete Flint byte-level vocabulary")
            }
            pieces.append(bytes)
        }
        self.init(pieces: pieces, stopTokenIDs: stopTokenIDs,
            answerStops: [150001, 150003], observationStop: 150005, fallbackTokenID: 150001)
    }

    /// Small immutable vocabularies also exercise the production byte machine
    /// in CPU-only tests, without a model, MLX array or checkpoint dependency.
    init(pieces: [[UInt8]], stopTokenIDs: Set<Int>, answerStops: Set<Int>,
         observationStop: Int, fallbackTokenID: Int) {
        self.pieces = pieces
        self.stopTokenIDs = stopTokenIDs
        self.answerStops = answerStops
        self.observationStop = observationStop
        self.fallbackTokenID = fallbackTokenID
        nonStopTokenIDs = pieces.indices.filter { !stopTokenIDs.contains($0) }
        markerCompleters = pieces.indices.filter { !stopTokenIDs.contains($0) && pieces[$0].contains(62) }
        keyDelimiters = pieces.indices.filter { !stopTokenIDs.contains($0) && pieces[$0].contains(60) }
        let significant: Set<UInt8> = [34, 92, 123, 125, 91, 93, 62]
        jsonSensitive = pieces.indices.filter {
            !stopTokenIDs.contains($0) && pieces[$0].contains(where: significant.contains)
        }
        let nonStop = pieces.indices.filter { !stopTokenIDs.contains($0) }
        jsonStringSensitive = nonStop.filter { id in
            pieces[id].contains { $0 < 0x20 || $0 == 34 || $0 == 92 || $0 == 62 }
        }
        byteOrderedTokenIDs = nonStop.sorted { pieces[$0].lexicographicallyPrecedes(pieces[$1]) }
            .map { Int32($0) }
        var buckets = [[Int]](repeating: [], count: 256)
        for id in pieces.indices where !stopTokenIDs.contains(id) {
            if let first = pieces[id].first { buckets[Int(first)].append(id) }
        }
        byFirstByte = buckets
        longestFirst = pieces.indices.filter { !stopTokenIDs.contains($0) }
            .sorted { pieces[$0].count > pieces[$1].count }
    }

    func keySensitive(remainingBytes: Int) -> [Int] {
        let oversized = longestFirst.prefix { pieces[$0].count > remainingBytes }
        return oversized.isEmpty ? keyDelimiters : Array(Set(keyDelimiters).union(oversized))
    }

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

    static func bytes(_ raw: String) -> [UInt8]? {
        var result = [UInt8]()
        for scalar in raw.unicodeScalars {
            guard let byte = byteDecoder[scalar] else { return nil }
            result.append(byte)
        }
        return result
    }

    /// Cache ownership follows existing tokenizer handles, without retaining a
    /// retired model. Four entries bound idle host memory; active requests own
    /// their immutable vocabulary independently of eviction.
    private final class Cache: @unchecked Sendable {
        private struct Entry {
            weak var owner: TokenizerHandle?
            let stops: Set<Int>
            let vocabulary: FlintNativeVocabulary
        }
        private let lock = NSLock()
        private var entries: [Entry] = []

        func get(_ handle: TokenizerHandle, stops: Set<Int>) throws -> FlintNativeVocabulary {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.owner == nil }
            if let index = entries.firstIndex(where: { $0.owner === handle && $0.stops == stops }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                return entry.vocabulary
            }
            let vocabulary = try FlintNativeVocabulary(tokenizer: handle.inner, stopTokenIDs: stops)
            if entries.count == 4 { entries.removeFirst() }
            entries.append(.init(owner: handle, stops: stops, vocabulary: vocabulary))
            return vocabulary
        }
    }
}

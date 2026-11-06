import CryptoKit
import Foundation

/// Strict reader for the coordinator-owned B policy bytes. Parsing establishes
/// equality only; approval is accepted exclusively on the live WSS connection.
struct NativePairMemberPolicy: Sendable {
    let bytes: Data
    let model: String
    let generation: UInt64
    let hashes: [Data]
    let schedule: UInt8
    let maximumFrame, maximumPlaintext: UInt32
    let maximumRecords, maximumCumulative, notAfter: UInt64
    let chips: [String]
    init(_ bytes: Data) throws {
        guard bytes.count <= 8192 else { throw NativePairMemberError.binding }
        var r = Reader(bytes)
        try r.literal(Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8))
        _ = try r.string(maximum: 128) // Policy ID is included in the exact digest.
        model = try r.string(maximum: 512); generation = try r.integer(UInt64.self)
        hashes = try (0..<8).map { _ in try r.read(32) }
        try r.literal(Data([1, 1])); schedule = try r.integer(UInt8.self)
        maximumFrame = try r.integer(UInt32.self); maximumPlaintext = try r.integer(UInt32.self)
        maximumRecords = try r.integer(UInt64.self); maximumCumulative = try r.integer(UInt64.self)
        notAfter = try r.integer(UInt64.self)
        let count = try r.integer(UInt32.self)
        guard (1...16).contains(count) else { throw NativePairMemberError.binding }
        chips = try (0..<count).map { _ in try r.string(maximum: 128) }
        guard r.remaining == 0, generation > 0, (1...2).contains(schedule),
              hashes.allSatisfy({ !$0.allSatisfy({ $0 == 0 }) }), chips == chips.sorted(), Set(chips).count == chips.count,
              maximumPlaintext > 0, maximumPlaintext <= 16 * 1024 * 1024,
              maximumFrame >= maximumPlaintext + 40, maximumFrame <= 16 * 1024 * 1024 + 40,
              (1...1_048_576).contains(maximumRecords), (1...4_294_967_296).contains(maximumCumulative),
              notAfter > 0, notAfter <= UInt64(Int64.max) else { throw NativePairMemberError.binding }
        self.bytes = bytes
    }
    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func read(_ n: Int) throws -> Data {
            guard n >= 0, n <= remaining else { throw NativePairMemberError.binding }
            defer { offset += n }; return data.subdata(in: offset..<(offset + n))
        }
        mutating func literal(_ expected: Data) throws {
            guard try read(expected.count) == expected else { throw NativePairMemberError.binding }
        }
        mutating func integer<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
            try read(MemoryLayout<T>.size).reduce(0) { ($0 << 8) | T($1) }
        }
        mutating func string(maximum: Int) throws -> String {
            let n = try integer(UInt32.self)
            guard n > 0, Int(n) <= maximum, let s = String(data: try read(Int(n)), encoding: .utf8) else { throw NativePairMemberError.binding }
            return s
        }
    }
}

enum NativePairMemberError: Error { case binding, deadline, inactive, queue, unconfigured }

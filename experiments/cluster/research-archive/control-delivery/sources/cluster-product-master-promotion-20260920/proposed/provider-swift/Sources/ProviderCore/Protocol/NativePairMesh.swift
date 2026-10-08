import Foundation

/// Closed public mirror of coordinator/protocol/native_pair_mesh.go. No caller
/// supplied lengths, inference data, native pointers or arbitrary collectives.
enum NativePairMesh {
    static func keyConfirmed(_ transcript: Data) throws -> Data {
        guard transcript.count == 32 else { throw NativePairMessage.Invalid.publicFrame }
        var out = Data([68, 66, 78, 75, 1]); out.append(transcript); return out
    }
    static func validate(round: UInt8, contribution: Data) throws {
        switch round {
        case 0: guard contribution == Data([2, 0, 0, 0]) else { throw NativePairMessage.Invalid.publicFrame }
        case 1: guard contribution.count == 64 else { throw NativePairMessage.Invalid.publicFrame }
        case 2, 3: guard contribution == Data([0, 0, 0, 0]) else { throw NativePairMessage.Invalid.publicFrame }
        default: throw NativePairMessage.Invalid.publicFrame
        }
    }
    static func packet(transcript: Data, rank: Int, round: UInt8, value: Data, reply: Bool = false) throws -> Data {
        guard transcript.count == 32, (0...1).contains(rank), round < 4 else { throw NativePairMessage.Invalid.publicFrame }
        let count = round == 1 ? 64 : 4
        if reply {
            guard value.count == count * 2 else { throw NativePairMessage.Invalid.publicFrame }
            for r in 0..<2 { try validate(round: round, contribution: Data(value.dropFirst(r * count).prefix(count))) }
        } else { try validate(round: round, contribution: value) }
        var out = Data([68, 66, 78, reply ? 71 : 77, 1]); out.append(transcript)
        out.append(UInt8(rank)); out.append(round); out.append(value); return out
    }
    static func decode(_ bytes: Data, transcript: Data, rank: Int, round: UInt8, reply: Bool = false) throws -> Data {
        guard bytes.count >= 39 else { throw NativePairMessage.Invalid.publicFrame }
        let value = Data(bytes.dropFirst(39))
        guard try packet(transcript: transcript, rank: rank, round: round, value: value, reply: reply) == bytes else { throw NativePairMessage.Invalid.publicFrame }
        return value
    }
}

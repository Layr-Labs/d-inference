import Foundation

struct Gemma4ShortWireValue: Codable, Equatable {
    let event: String
    var sequence = 0, frontier = 0, count = 0
    var tokenIDsSHA256: String? = nil
    var payloadSHA256: String? = nil
    var tokenID: Int? = nil
    var dtype: String? = nil
}

struct Gemma4ShortWirePacket: Codable {
    let schema: String, scopeSHA256: String
    let senderRank: Int, ordinal: Int
    let value: Gemma4ShortWireValue
}

/// Fixed short operation geometry; no values from the wire authorize allocation.
enum Gemma4ShortFrames {
    static func frame(_ sequence: Int) throws -> QwenLayerStageFrame {
        switch sequence {
        case 0: return .init(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 16, finalPromptChunk: false)
        case 1: return .init(sequence: 1, phase: .prefill, tokenOffset: 16, tokenCount: 16, finalPromptChunk: true)
        case 2: return .init(sequence: 2, phase: .decode, tokenOffset: 32, tokenCount: 1, finalPromptChunk: false)
        default: throw ProbeError("Gemma short frame is outside its three committed evaluations")
        }
    }

    static func probeCount(_ sequence: Int) throws -> Int {
        guard (0...1).contains(sequence) else { throw ProbeError("Gemma short probe phase differs") }
        return sequence == 0 ? 2 : 1
    }
}

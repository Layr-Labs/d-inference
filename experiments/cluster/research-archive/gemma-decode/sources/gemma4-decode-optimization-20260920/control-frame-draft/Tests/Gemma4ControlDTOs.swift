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


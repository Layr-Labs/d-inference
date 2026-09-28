import Foundation

enum Gemma4ShortWireCodec {
    static func decode(_ data: Data, scope: String, sender: Int, ordinal: Int) throws -> Gemma4ShortWireValue {
        let object = try QwenLayerStageGenerationWireJSON.object(data)
        let packet = try JSONDecoder().decode(Gemma4ShortWirePacket.self, from: data)
        try QwenLayerStageGenerationWireJSON.requireExact(object, packet)
        guard packet.schema == "gemma4_short_p2p_v1", packet.scopeSHA256 == scope,
              packet.senderRank == sender, packet.ordinal == ordinal,
              (0...1).contains(sender), (0..<64).contains(ordinal), qwenStageWireIsSHA256(scope) else {
            throw ProbeError("Gemma peer operation/role/strict ordinal differs")
        }
        return packet.value
    }
}

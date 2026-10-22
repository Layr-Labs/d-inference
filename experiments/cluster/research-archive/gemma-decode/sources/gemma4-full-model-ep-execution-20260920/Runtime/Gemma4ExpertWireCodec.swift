import Foundation

struct Gemma4ExpertWireValue: Codable, Equatable {
    let event: String
    var layerScopeSHA256: String? = nil
    var rows: Int? = nil
    var payloadBytes: Int? = nil
    var payloadSHA256: String? = nil
    var frame: QwenLayerStageFrame? = nil
    var tokenIDsSHA256: String? = nil
    var rowSHA256: String? = nil
    var tokenID: Int? = nil

    func event(_ name: String) -> Self { .init(event: name,
        layerScopeSHA256: layerScopeSHA256, rows: rows, payloadBytes: payloadBytes,
        payloadSHA256: payloadSHA256, frame: frame, tokenIDsSHA256: tokenIDsSHA256,
        rowSHA256: rowSHA256, tokenID: tokenID) }
}

struct Gemma4ExpertWirePacket: Codable {
    let schema: String
    let scopeSHA256: String
    let senderRank: Int
    let ordinal: Int
    let value: Gemma4ExpertWireValue
}

enum Gemma4ExpertWireCodec {
    static func requireRows(_ actual: Gemma4ExpertWireValue, rows: Int,
                            limit: Int, layerScope: String) throws -> String {
        guard limit >= 0, limit <= ExpertAxisQualificationLimits.maximumAssignments, (0...limit).contains(rows),
              qwenStageWireIsSHA256(layerScope), let hash = actual.payloadSHA256,
              qwenStageWireIsSHA256(hash), rows != 0 || hash == sha256(Data()),
              actual == .init(event:"rows",layerScopeSHA256:layerScope,rows:rows,
                  payloadBytes:rows*2816*2,payloadSHA256:hash) else {
            throw ProbeError("Gemma EP header differs before receiver allocation")
        }
        return hash
    }
    static func decode(_ data: Data, scope: String, sender: Int, ordinal: Int) throws -> Gemma4ExpertWireValue {
        guard (1...Gemma4ExpertResourceTerms.controlBytes).contains(data.count) else {
            throw ProbeError("Gemma EP control exceeds its fixed byte limit")
        }
        try validateWorkerJSON(data)
        let packet = try JSONDecoder().decode(Gemma4ExpertWirePacket.self, from: data)
        guard ["begin","ready","layer","rows","rows-ready","rows-consumed","frame-committed", "request-retired","model-released"].contains(packet.value.event),
              packet.schema == "gemma4_full_expert_wire_v1", packet.scopeSHA256 == scope,
              packet.senderRank == sender, packet.ordinal == ordinal else {
            throw ProbeError("Gemma EP packet scope/rank/sequence differs")
        }
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(data), packet)
        return packet.value
    }
}

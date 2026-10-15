import Foundation

struct ExpertAxisRDMAJob: Codable {
    let schema: String, modelDirectory: String, membershipEpoch: String, requestID: String
    let buildIdentitySHA256: String, ownership: String
    let rank: Int, layer: Int, tokenCounts: [Int], timeoutSeconds: Int

    func validate() throws {
        let path = URL(fileURLWithPath: modelDirectory)
        guard schema == "gemma4_expert_rdma_check_v1", (0...1).contains(rank), (0..<30).contains(layer),
              ["contiguous48_80", "strided43_85"].contains(ownership),
              !tokenCounts.isEmpty, tokenCounts.count <= 5, tokenCounts == tokenCounts.sorted(),
              Set(tokenCounts).count == tokenCounts.count, tokenCounts.allSatisfy({ [1,7,8,9,33].contains($0) }),
              (1...300).contains(timeoutSeconds), qwenStageWireIsSHA256(buildIdentitySHA256),
              [membershipEpoch, requestID].allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              modelDirectory.hasPrefix("/"), modelDirectory.utf8.count <= 2048, !modelDirectory.contains("\0"),
              path.standardizedFileURL.path == modelDirectory else {
            throw ProbeError("Expert RDMA job is outside its closed source/workload/identity bounds")
        }
    }
    func expertOwnership() throws -> ExpertIDOwnership {
        try validate()
        return try .init(expertCount: 128, globalIDsByRank: ownership == "contiguous48_80"
            ? [Array(0..<48), Array(48..<128)]
            : [(0..<128).filter { $0 % 3 == 0 }, (0..<128).filter { $0 % 3 != 0 }])
    }
    var scopeSHA256: String {
        sha256(Data([schema, membershipEpoch, requestID, buildIdentitySHA256, ownership,
            "layer=\(layer)", "tokens=" + tokenCounts.map(String.init).joined(separator: ","),
            "timeout=\(timeoutSeconds)", Gemma4ArtifactMetadata.artifactAggregateSHA256,
            Gemma4ArtifactMetadata.configurationSHA256,
            "bf16-w4-g64-original-top8-slots-v1"].joined(separator: "\n").utf8))
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 16_384 else { throw ProbeError("Expert RDMA job exceeds16KiB") }
        try validateWorkerJSON(bytes)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes), value)
        return value
    }
}

/// Only bounded public numerical-fixture metadata travels in this control DTO.
/// Tensor values use the completed P2P path; this is checksum binding, not AEAD.
struct ExpertAxisRDMAControl: Codable, Equatable {
    var event: String
    var caseIndex = -1
    var rows = 0
    var payloadBytes = 0
    var payloadSHA256 = ""
    var routeSHA256 = ""
    var inputSHA256 = ""
    var weightsSHA256 = ""
    var selectedGlobalIDs: [[Int]] = []
    var resultSHA256 = ""
    var accepted = false
    func changingEvent(_ value: String) -> Self { var copy = self; copy.event = value; return copy }
}

struct ExpertAxisRDMAPacket: Codable {
    let schema: String, scopeSHA256: String
    let senderRank: Int, ordinal: Int
    let value: ExpertAxisRDMAControl
}

enum ExpertAxisRDMACodec {
    static let controlLimit = 32_768, payloadLimit = 2_097_152, recordLimit = 128
    static func decode(_ bytes: Data, scope: String, sender: Int, ordinal: Int) throws -> ExpertAxisRDMAControl {
        guard (1...controlLimit).contains(bytes.count), (0...1).contains(sender),
              (0..<recordLimit).contains(ordinal), qwenStageWireIsSHA256(scope) else {
            throw ProbeError("Expert RDMA packet bounds differ")
        }
        try validateWorkerJSON(bytes)
        let packet = try JSONDecoder().decode(ExpertAxisRDMAPacket.self, from: bytes)
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes), packet)
        guard packet.schema == "gemma4_expert_rdma_wire_v1", packet.scopeSHA256 == scope,
              packet.senderRank == sender, packet.ordinal == ordinal else {
            throw ProbeError("Expert RDMA packet scope/direction/sequence differs")
        }
        return packet.value
    }
    static func routeDigest(_ selected: [[Int]]) throws -> String { sha256(try canonicalJSONData(selected)) }
    static func validateRoute(_ value: ExpertAxisRDMAControl, job: ExpertAxisRDMAJob, index: Int) throws -> ExpertDispatchPlan {
        guard job.tokenCounts.indices.contains(index), value.event == "route", value.caseIndex == index,
              value.rows == job.tokenCounts[index], value.payloadBytes == 0, value.payloadSHA256.isEmpty,
              value.resultSHA256.isEmpty, !value.accepted, value.selectedGlobalIDs.count == value.rows,
              value.selectedGlobalIDs.allSatisfy({ $0.count == 8 }),
              qwenStageWireIsSHA256(value.inputSHA256), qwenStageWireIsSHA256(value.weightsSHA256),
              value.routeSHA256 == (try routeDigest(value.selectedGlobalIDs)) else {
            throw ProbeError("Expert RDMA route differs from local admitted case")
        }
        return try ExpertDispatchPlan(ownership: job.expertOwnership(), selectedGlobalIDs: value.selectedGlobalIDs,
                                      maxAssignments: 33 * 8)
    }
}

import Foundation

/// Compiled into the private executable; metadata and pure records only.
/// Never constructs a model/owner/Collective or calls an MLX array API.
enum Gemma4ExpertExecutionChecks {
    static func run(input: Gemma4ExpertCorrectnessInput) throws -> Data {
        var checks = 0
        func require(_ value: Bool) throws {
            guard value else { throw ProbeError("Gemma EP execution metadata control failed") }; checks += 1
        }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw ProbeError("Gemma EP execution metadata control failed to refuse")
        }
        let scope = String(repeating: "a", count: 64)
        let packet = Gemma4ExpertWirePacket(schema: "gemma4_full_expert_wire_v1",
            scopeSHA256: scope, senderRank: 0, ordinal: 9,
            value: .init(event: "rows", layerScopeSHA256: String(repeating: "b", count: 64),
                rows: 0, payloadBytes: 0, payloadSHA256: sha256(Data())))
        let bytes = try canonicalJSONData(packet)
        func decode(_ data: Data) throws -> Gemma4ExpertWireValue {
            try Gemma4ExpertWireCodec.decode(data, scope: scope, sender: 0, ordinal: 9)
        }
        try require(try decode(bytes) == packet.value)
        let object = try QwenLayerStageGenerationWireJSON.object(bytes)
        for (key,replacement) in [("schema","wrong"), ("scopeSHA256",String(repeating:"c",count:64))] {
            var changed = object; changed[key] = replacement
            try refuses { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        }
        for (key,replacement) in [("senderRank",1), ("ordinal",8)] {
            var changed = object; changed[key] = replacement
            try refuses { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        }
        var changed = object; changed["unknown"] = true
        try refuses { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        changed = object; changed.removeValue(forKey: "ordinal")
        try refuses { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        changed = object
        var value = try QwenLayerStageGenerationWireJSON.object(canonicalJSONData(packet.value))
        value["event"] = "late-success"; changed["value"] = value
        try refuses { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        let text = String(decoding:bytes,as:UTF8.self)
        try refuses { _ = try decode(Data(text.replacingOccurrences(of: "\"ordinal\":9", with: "\"ordinal\":9,\"ordinal\":9").utf8)) }
        try refuses { _ = try decode(Data(repeating: 32,count:Gemma4ExpertResourceTerms.controlBytes+1)) }
        try refuses { _ = try decode(Data()) }
        let layerScope = String(repeating:"d",count:64)
        let empty = Gemma4ExpertWireValue(event:"rows",layerScopeSHA256:layerScope,
            rows:0,payloadBytes:0,payloadSHA256:sha256(Data()))
        try require(try Gemma4ExpertWireCodec.requireRows(empty,rows:0,limit:128,layerScope:layerScope) == sha256(Data()))
        for invalid in [empty.event("rows-consumed"),
            Gemma4ExpertWireValue(event:"rows",layerScopeSHA256:layerScope,rows:0,payloadBytes:2,payloadSHA256:sha256(Data())),
            Gemma4ExpertWireValue(event:"rows",layerScopeSHA256:layerScope,rows:0,payloadBytes:0,payloadSHA256:scope),
            Gemma4ExpertWireValue(event:"rows",layerScopeSHA256:scope,rows:0,payloadBytes:0,payloadSHA256:sha256(Data()))] {
            try refuses { _ = try Gemma4ExpertWireCodec.requireRows(invalid,rows:0,limit:128,layerScope:layerScope) }
        }
        let payload = Gemma4ExpertWireValue(event:"rows",layerScopeSHA256:layerScope,
            rows:128,payloadBytes:128*2816*2,payloadSHA256:scope)
        try require(try Gemma4ExpertWireCodec.requireRows(payload,rows:128,limit:128,layerScope:layerScope) == scope)
        try refuses { _ = try Gemma4ExpertWireCodec.requireRows(payload,rows:129,limit:128,layerScope:layerScope) }
        try refuses { _ = try Gemma4ExpertWireCodec.requireRows(payload,rows:128,limit:127,layerScope:layerScope) }

        let full = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.fullReference,
            request:input.request,bound:{$0})
        var budgets: [[String:Any]] = []
        let maps = [[Array(0..<48),Array(48..<128)],
                    [(0..<128).filter{$0%3==0},(0..<128).filter{$0%3 != 0}],
                    [Array(0..<32),Array(32..<128)]]
        for map in maps {
            for rank in 0..<2 {
                let partition = try Gemma4ExpertPartition(rank:rank,globalIDsByRank:map)
                let budget = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.expertParallel(partition),
                    request:input.request,bound:{$0})
                guard let terms = budget.expertResources else { throw ProbeError("EP ledger absent") }
                try require(budget.stateLayers == full.stateLayers && budget.stateLogicalBytes == full.stateLogicalBytes)
                try require(budget.selected.count == 1339 && budget.selectedBounds.reduce(0,+)
                    == 1_621_321_788 + map[rank].count * 30 * 3_345_408)
                try require(terms.assignmentLimit == 128 && terms.payloadByteLimit == 128*2816*2)
                try require(terms.arrayTerms.count == 575 && Set(terms.arrayTerms.map(\.name)).count == 575)
                try require(terms.collectiveNativeAllowanceBytes == 32*1_048_576
                    && terms.collectiveHostAllowanceBytes == 32*1_048_576
                    && terms.hostBytes >= terms.collectiveHostAllowanceBytes + 1_048_576)
                try require(budget.namedNativeBytes == budget.namedAllocationBounds.reduce(0,+))
                let adjacent = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.expertParallel(partition),
                    request:input.request,expertTemporaryPolicy:.adjacentSynchronousV1,bound:{$0})
                guard let adjacentTerms = adjacent.expertResources else { throw ProbeError("Adjacent EP ledger absent") }
                let legacyObject = try JSONSerialization.jsonObject(with: canonicalJSONData(terms)) as? [String:Any]
                let adjacentObject = try JSONSerialization.jsonObject(with: canonicalJSONData(adjacentTerms)) as? [String:Any]
                try require(legacyObject?["temporaryLivenessPolicy"] == nil
                    && (adjacentObject?["temporaryLivenessPolicy"] as? String)
                        == Gemma4ExpertTemporaryPolicy.adjacentSynchronousV1.rawValue)
                try require(adjacentTerms.arrayTerms.count == 43
                    && Set(adjacentTerms.arrayTerms.map(\.name)).count == 43)
                let originalTrunk = budget.namedArrays.filter { !$0.name.contains(":ep:") && !$0.name.hasPrefix("ep:") }
                let adjacentTrunk = adjacent.namedArrays.filter { !$0.name.contains(":ep:") && !$0.name.hasPrefix("ep:") }
                try require(zip(originalTrunk,adjacentTrunk).allSatisfy { $0.0.name == $0.1.name && $0.0.bytes == $0.1.bytes }
                    && originalTrunk.count == adjacentTrunk.count)
                try require(adjacent.stateLayers == budget.stateLayers && adjacent.stateLogicalBytes == budget.stateLogicalBytes
                    && adjacent.persistentCastLogicalBytes == budget.persistentCastLogicalBytes
                    && adjacent.selectedBounds == budget.selectedBounds
                    && adjacent.largestHostTensorBytes == budget.largestHostTensorBytes
                    && adjacent.largestNativeCopyBytes == budget.largestNativeCopyBytes)
                // Independent exact shape arithmetic: nine hidden arrays, three
                // intermediate arrays and seven U32 index arrays per EP layer.
                let perLayer = 128 * (9 * 2816 * 4 + 3 * 704 * 4 + 7 * 4)
                try require(perLayer == 14_061_056
                    && budget.namedNativeBytes - adjacent.namedNativeBytes == 28 * perLayer
                    && adjacent.hostEvidenceBytes - budget.hostEvidenceBytes == 4_096)
                try require(adjacentTerms.policy == "gemma4_full_expert_correctness_resources_v2"
                    && adjacentTerms.temporaryLivenessPolicy == .adjacentSynchronousV1
                    && adjacentTerms.collectiveNativeAllowanceBytes == terms.collectiveNativeAllowanceBytes
                    && adjacentTerms.collectiveHostAllowanceBytes == terms.collectiveHostAllowanceBytes)
                for count in [17,64,128] {
                    try refuses { _ = try Gemma4ExpertResourceTerms.derive(partition:partition,
                        frameTokens:count,temporaryPolicy:.adjacentSynchronousV1) }
                }
                try refuses { _ = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.fullReference,
                    request:input.request,expertTemporaryPolicy:.adjacentSynchronousV1,bound:{$0}) }
                let roundedAdjacent = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.expertParallel(partition),
                    request:input.request,expertTemporaryPolicy:.adjacentSynchronousV1,
                    bound:{ (($0+16_383)/16_384)*16_384 })
                try require(roundedAdjacent.namedNativeBytes == roundedAdjacent.namedAllocationBounds.reduce(0,+)
                    && roundedAdjacent.namedNativeBytes >= adjacent.namedNativeBytes)
                let rounded = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:.expertParallel(partition),
                    request:input.request,bound:{ (($0+16_383)/16_384)*16_384 })
                try require(rounded.namedNativeBytes >= budget.namedNativeBytes
                    && zip(rounded.selectedBounds,budget.selectedBounds).allSatisfy{$0.0 >= $0.1})
                try refuses { _ = try Gemma4ShortResourceBudget.derive(plan:input.plan,
                    target:.expertParallel(partition),request:input.request,bound:{$0-1}) }
                for tokenCount in [2,16,64,128] {
                    let extended = try Gemma4ExpertResourceTerms.derive(partition:partition,frameTokens:tokenCount)
                    try require(extended.assignmentLimit == tokenCount*8 && extended.payloadByteLimit == tokenCount*8*2816*2)
                }
                for count in [1,129,Int.max] {
                    try refuses { _ = try Gemma4ExpertResourceTerms.derive(partition:partition,frameTokens:count) }
                }
                budgets.append(["rank":rank,"ownedExperts":map[rank].count,
                    "selectedBytes":budget.selectedBounds.reduce(0,+),"namedNativeBytes":budget.namedNativeBytes,
                    "hostBytes":budget.hostEvidenceBytes,"stateBytes":budget.stateLogicalBytes,
                    "actualAdmissionEstablished":false])
            }
        }
        let encoding = try Gemma4ExpertEncodingChecks.run(input:input)
        return try JSONSerialization.data(withJSONObject:["schema":"gemma4_full_expert_local_checks_v1",
            "checks":checks,"budgets":budgets,"encoding":encoding,"modelConstructed":false,
            "payloadRead":false,"collectiveCreated":false,"nativeExecuted":false,
            "actualAdmissionEstablished":false],options:[.sortedKeys])
    }
}

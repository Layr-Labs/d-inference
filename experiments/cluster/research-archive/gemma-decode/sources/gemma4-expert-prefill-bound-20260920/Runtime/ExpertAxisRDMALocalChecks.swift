import Foundation

/// Metadata-only positive/negative controls of the real wire/route decoder.
/// No MLX array, collective, file/model read or supplied release proof is used.
enum ExpertAxisRDMALocalChecks {
    static func run() throws -> Data {
        var groups: [String] = []
        let job = ExpertAxisRDMAJob(schema: "gemma4_expert_rdma_check_v1", modelDirectory: "/fixture/gemma",
            membershipEpoch: "a7d2c7ab-cc2f-4d16-93d4-bd820c3e27a1", requestID: "6bdacda5-714b-45d0-a9f9-e9a790506102",
            buildIdentitySHA256: String(repeating: "a", count: 64), ownership: "contiguous48_80",
            rank: 0, layer: 0, tokenCounts: ExpertAxisQualificationLimits.extendedCases, timeoutSeconds: 300)
        let encodedJob = try canonicalJSONData(job)
        let decoded = try ExpertAxisRDMAJob.decode(encodedJob)
        guard decoded.scopeSHA256 == job.scopeSHA256 else { throw ProbeError("Expert local job roundtrip differs") }
        func changedJob(_ values: [String: Any]) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
            for (key,value) in values { object[key] = value }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func refuse(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw ProbeError("Expert RDMA invalid local contract was accepted")
        }
        let peer = try ExpertAxisRDMAJob.decode(changedJob(["rank": 1, "modelDirectory": "/other/fixture/gemma"]))
        guard peer.scopeSHA256 == job.scopeSHA256,
              try job.expertOwnership().globalIDsByRank.map(\.count) == [48,80] else { throw ProbeError("Expert common source scope differs") }
        let strided = try ExpertAxisRDMAJob.decode(changedJob(["ownership": "strided43_85"]))
        guard try strided.expertOwnership().globalIDsByRank.map(\.count) == [43,85], strided.scopeSHA256 != job.scopeSHA256 else {
            throw ProbeError("Expert ownership is not bound")
        }
        groups.append("canonical-common-scope-and-both-ownerships")
        let invalidJobs: [[String: Any]] = [["rank": 2], ["layer": 30], ["tokenCounts": [34]], ["tokenCounts": [129]], ["tokenCounts": [1,1]],
            ["timeoutSeconds": 301], ["ownership": "balanced"], ["modelDirectory": "/fixture/../gemma"],
            ["buildIdentitySHA256": "unsigned"], ["ignored": true]]
        for changed in invalidJobs {
            try refuse { _ = try ExpertAxisRDMAJob.decode(changedJob(changed)) }
        }
        groups.append("job-bounds-and-unknown-fields")
        func route(_ selected: [[Int]], index: Int) throws -> ExpertAxisRDMAControl {
            var value = ExpertAxisRDMAControl(event: "route", caseIndex: index, rows: selected.count)
            value.selectedGlobalIDs = selected; value.routeSHA256 = try ExpertAxisRDMACodec.routeDigest(selected)
            value.inputSHA256 = String(repeating: "b", count: 64); value.weightsSHA256 = String(repeating: "c", count: 64)
            return value
        }
        for ids in [Array(0..<8), Array(48..<56), [0,48,1,49,2,50,3,51]] {
            let value = try route([ids], index: 0)
            let plan = try ExpertAxisRDMACodec.validateRoute(value, job: job, index: 0)
            let order = try plan.reassemblyIndices(returnedByRank: plan.assignmentsByRank)
            let returned = plan.assignmentsByRank.flatMap { $0 }
            guard order.map({ returned[$0].globalExpertID }) == ids else { throw ProbeError("Expert original top-k order changed") }
        }
        groups.append("empty-ranks-and-mixed-original-slot-order")
        let selected = (0..<128).map { row in (0..<8).map { (row*7+$0*3)%128 } }
        let maximum = try route(selected, index: 6)
        let maximumPlan = try ExpertAxisRDMACodec.validateRoute(maximum, job: job, index: 6)
        guard maximumPlan.assignmentCount == 1024, 1024*2816*2 <= ExpertAxisRDMACodec.payloadLimit else {
            throw ProbeError("Expert maximum route/transfer does not fit closed bound")
        }
        groups.append("maximum-real-assignment-envelope")
        try refuse { _ = try ExpertAxisRDMACodec.validateRoute(route([[0,0,1,2,3,4,5,6]], index: 0), job: job, index: 0) }
        try refuse { _ = try ExpertAxisRDMACodec.validateRoute(route([[0,1,2,3,4,5,6,128]], index: 0), job: job, index: 0) }
        try refuse { _ = try ExpertAxisRDMACodec.validateRoute(maximum, job: job, index: 0) }
        var badDigest = maximum; badDigest.routeSHA256 = String(repeating: "d", count: 64)
        try refuse { _ = try ExpertAxisRDMACodec.validateRoute(badDigest, job: job, index: 6) }
        var badWeights = maximum; badWeights.weightsSHA256 = ""
        try refuse { _ = try ExpertAxisRDMACodec.validateRoute(badWeights, job: job, index: 6) }
        groups.append("malformed-route-substitution-and-stale-case")
        let packet = try canonicalJSONData(ExpertAxisRDMAPacket(schema: "gemma4_expert_rdma_wire_v1",
            scopeSHA256: job.scopeSHA256, senderRank: 0, ordinal: 3, value: maximum))
        guard try ExpertAxisRDMACodec.decode(packet, scope: job.scopeSHA256, sender: 0, ordinal: 3) == maximum else {
            throw ProbeError("Expert packet canonical roundtrip differs")
        }
        try refuse { _ = try ExpertAxisRDMACodec.decode(packet, scope: strided.scopeSHA256, sender: 0, ordinal: 3) }
        try refuse { _ = try ExpertAxisRDMACodec.decode(packet, scope: job.scopeSHA256, sender: 1, ordinal: 3) }
        try refuse { _ = try ExpertAxisRDMACodec.decode(packet, scope: job.scopeSHA256, sender: 0, ordinal: 4) }
        try refuse { _ = try ExpertAxisRDMACodec.decode(packet, scope: job.scopeSHA256, sender: 0, ordinal: 128) }
        groups.append("wire-scope-direction-replay-and-exhaustion")
        var extra = try JSONSerialization.jsonObject(with: packet) as! [String: Any]; extra["ignored"] = true
        try refuse { _ = try ExpertAxisRDMACodec.decode(JSONSerialization.data(withJSONObject: extra), scope: job.scopeSHA256, sender: 0, ordinal: 3) }
        try refuse { _ = try ExpertAxisRDMACodec.decode(packet.dropLast(), scope: job.scopeSHA256, sender: 0, ordinal: 3) }
        try refuse { _ = try ExpertAxisRDMACodec.decode(Data(repeating: 32, count: 32_769), scope: job.scopeSHA256, sender: 0, ordinal: 3) }
        groups.append("unknown-truncated-and-overbound-control")
        return try JSONSerialization.data(withJSONObject: ["schema": "gemma4_expert_rdma_local_checks_v1", "groups": groups,
            "passed": true, "nativeExecuted": false, "modelPayloadRead": false], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

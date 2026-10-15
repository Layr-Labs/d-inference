import Foundation
import MLX
import MLXLMCommon

struct ExpertAxisRDMACaseObservation: Encodable {
    let ordinal: Int, tokenCount: Int, localAssignmentCount: Int
    let routeSHA256: String, inputSHA256: String, weightsSHA256: String
    let transferredOutputSHA256: String, referenceResultSHA256: String
    let acceptedByReferenceRank: Bool
    let comparison: ExpertAxisCaseResult?
}

enum ExpertAxisRDMACase {
    static func run(job: ExpertAxisRDMAJob, index: Int, ownership: ExpertIDOwnership,
                    localBank: ExpertAxisBank, reference: ExpertAxisBank?, router: ExpertAxisRouterReplay?,
                    wire: ExpertAxisRDMAWire, check: () throws -> Void) throws -> ExpertAxisRDMACaseObservation {
        try check()
        let rows = job.tokenCounts[index]
        let packet: ExpertAxisRDMAControl
        let input: MLXArray
        let weights: MLXArray?
        if job.rank == 0 {
            guard let router, reference != nil else { throw ProbeError("Authoritative expert rank lacks its actual reference/router") }
            let residual = ExpertAxisCheckCases.input(rows: rows, hidden: 2816, dtype: .bfloat16)
            let route = router.route(residual)
            eval(route.input, route.ids, route.weights); try check()
            // Explicit fixture-only CPU routing boundary. This is not a device-
            // only router/dispatch claim and is not inside an inference timer.
            let ids = route.ids.asArray(UInt32.self); try check()
            guard ids.count == rows*8, route.input.shape == [rows,2816], route.input.dtype == .bfloat16,
                  route.weights.shape == [rows,8], route.weights.dtype == .bfloat16 else {
                throw ProbeError("Actual expert router replay differs from admitted geometry")
            }
            let selected = (0..<rows).map { row in (0..<8).map { Int(ids[row*8+$0]) } }
            var value = ExpertAxisRDMAControl(event: "route", caseIndex: index, rows: rows)
            value.selectedGlobalIDs = selected; value.routeSHA256 = try ExpertAxisRDMACodec.routeDigest(selected)
            value.inputSHA256 = sha256(route.input.asData(access: .copy).data); try check()
            value.weightsSHA256 = sha256(route.weights.asData(access: .copy).data); try check()
            _ = try ExpertAxisRDMACodec.validateRoute(value, job: job, index: index)
            packet = value; input = route.input; weights = route.weights
            try wire.send(packet, check: check)
            try wire.require(packet.changingEvent("route-accepted"), check: check)
            guard try wire.sendTensor(input, event: "input", rows: rows, index: index,
                route: packet.routeSHA256, check: check) == packet.inputSHA256 else {
                throw ProbeError("Authoritative routed input changed before publication")
            }
        } else {
            guard reference == nil, router == nil else { throw ProbeError("Follower expert rank must not load reference/router") }
            packet = try wire.receive(check: check)
            _ = try ExpertAxisRDMACodec.validateRoute(packet, job: job, index: index)
            try wire.send(packet.changingEvent("route-accepted"), check: check)
            let incoming = try wire.receiveTensor(event: "input", rows: rows, index: index,
                route: packet.routeSHA256, expectedSHA256: packet.inputSHA256, check: check)
            guard let value = incoming.0 else { throw ProbeError("Expert input transfer is empty") }
            input = value; weights = nil
        }
        let dispatch = try ExpertAxisRDMADispatch(ownership: ownership, selected: packet.selectedGlobalIDs,
            rank: job.rank, check: check)
        let local = try dispatch.localUnweighted(input, bank: localBank)
        if let local { eval(local); try check() }
        let outputSHA: String
        let comparison: ExpertAxisCaseResult?
        let result: ExpertAxisRDMAControl
        if job.rank == 0 {
            guard let reference, let router, let weights else { throw ProbeError("Expert reference ownership disappeared") }
            let remote = try wire.receiveTensor(event: "unweighted-output", rows: dispatch.base.plan.assignmentCountsByRank[1],
                index: index, route: packet.routeSHA256, check: check)
            outputSHA = remote.1
            let candidateOutputs = try dispatch.reassemble([local,remote.0])
            let expectedOutputs = reference.module(input, dispatch.base.globalIDs)
            let outputs = try compareExpertAxis(expectedOutputs, candidateOutputs, check: check)
            let expected = weightedExpertSum(expectedOutputs, weights)
            let candidate = try dispatch.base.weighted(candidateOutputs, weights: weights)
            let weighted = try compareExpertAxis(expected, candidate, check: check)
            let postNorm = try compareExpertAxis(router.postNorm(expected), router.postNorm(candidate), check: check)
            guard sha256(weights.asData(access: .copy).data) == packet.weightsSHA256 else {
                throw ProbeError("Expert original router weights changed")
            }
            try check()
            let value = ExpertAxisCaseResult(label: "checkpoint-layer-\(job.layer)/two-rank/\(job.ownership)",
                inputDType: "bfloat16", tokenCount: rows, topK: 8,
                assignmentCounts: dispatch.base.plan.assignmentCountsByRank, selectedGlobalIDs: packet.selectedGlobalIDs,
                projectionPolicies: dispatch.base.projectionPolicies,
                routingWeightsSHA256: packet.weightsSHA256, expertOutputs: outputs, weighted: weighted, postNorm: postNorm)
            comparison = value
            var terminal = ExpertAxisRDMAControl(event: "result", caseIndex: index, rows: rows)
            terminal.routeSHA256 = packet.routeSHA256; terminal.resultSHA256 = sha256(try canonicalJSONData(value))
            terminal.accepted = value.passed; result = terminal
            try wire.send(result, check: check)
            try wire.require(result.changingEvent("result-accepted"), check: check)
        } else {
            outputSHA = try wire.sendTensor(local, event: "unweighted-output",
                rows: dispatch.base.plan.assignmentCountsByRank[1], index: index, route: packet.routeSHA256, check: check)
            let received = try wire.receive(check: check)
            var expected = ExpertAxisRDMAControl(event: "result", caseIndex: index, rows: rows)
            expected.routeSHA256 = packet.routeSHA256; expected.resultSHA256 = received.resultSHA256
            expected.accepted = received.accepted
            guard received == expected, qwenStageWireIsSHA256(received.resultSHA256) else {
                throw ProbeError("Expert comparison receipt differs from exact routed case")
            }
            result = received; comparison = nil
            try wire.send(result.changingEvent("result-accepted"), check: check)
        }
        try check()
        return .init(ordinal: index, tokenCount: rows, localAssignmentCount: dispatch.base.plan.assignmentCountsByRank[job.rank],
            routeSHA256: packet.routeSHA256, inputSHA256: packet.inputSHA256, weightsSHA256: packet.weightsSHA256,
            transferredOutputSHA256: outputSHA, referenceResultSHA256: result.resultSHA256,
            acceptedByReferenceRank: result.accepted, comparison: comparison)
    }
}

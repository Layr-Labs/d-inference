import Foundation

struct PlacementMemoryAssessment: Codable, Sendable {
    let rank: Int
    let phase: PlacementPhase
    let weightBytes: UInt64
    let additionalLiveBytes: UInt64
    let minimumFreeBytes: UInt64
    let guardBytes: UInt64
    let requiredAvailableBytes: UInt64
    let observedAvailableBytes: UInt64
    let memoryEvidenceSHA256: String
    let observationEvidenceSHA256: String
}

struct PlacementProposal: Codable, Sendable {
    let candidateID: String
    let adapterRecipeSHA256: String
    let prefillLayout: PlacementLayout
    let decodeLayout: PlacementLayout
    let memory: [PlacementMemoryAssessment]
    let prefill: PlacementSchedule
    let transition: PlacementSchedule
    let decode: PlacementSchedule
    let firstTokenNanoseconds: UInt64
    let transitionNanoseconds: UInt64
    let steadyDecodeNanosecondsPerToken: UInt64?
    let totalRequestNanoseconds: UInt64
}

struct PlacementRefusal: Codable, Sendable { let candidateID: String; let reason: String }
enum PlacementObjective: String, Codable, Sendable { case firstToken, steadyDecode, totalRequest }
struct PlacementReport: Codable, Sendable {
    let identity: PlacementIdentity
    let workload: PlacementWorkload
    let basis: PlacementCostBasis
    let objective: PlacementObjective
    let preferredCandidateID: String?
    let paretoCandidateIDs: [String]
    let proposals: [PlacementProposal]
    let refused: [PlacementRefusal]
    let predictionOnly: Bool
}

enum MeasuredPlacementPlanner {
    static func plan(_ request: PlacementRequest, measurements: PlacementMeasurements,
                     objective: PlacementObjective) throws -> PlacementReport {
        try PlacementValidation.request(request)
        let costs = try PlacementCostLookup(measurements, request: request)
        var proposals = [PlacementProposal](), refused = [PlacementRefusal]()
        for candidate in request.candidates {
            do { proposals.append(try assess(candidate, request: request, costs: costs)) }
            catch { refused.append(.init(candidateID: candidate.id, reason: String(describing: error))) }
        }
        proposals.sort { lhs, rhs in
            let a = score(lhs, objective), b = score(rhs, objective)
            return a == b ? lhs.candidateID < rhs.candidateID : a.lexicographicallyPrecedes(b)
        }
        let pareto = proposals.filter { candidate in
            !proposals.contains { other in
                let a = score(other, .firstToken), b = score(candidate, .firstToken)
                return a[0] <= b[0] && a[1] <= b[1] && a[2] <= b[2] &&
                    (a[0] < b[0] || a[1] < b[1] || a[2] < b[2])
            }
        }.map(\.candidateID).sorted()
        return .init(identity: request.identity, workload: request.workload, basis: request.policy.costBasis,
                     objective: objective, preferredCandidateID: proposals.first?.candidateID,
                     paretoCandidateIDs: pareto, proposals: proposals, refused: refused, predictionOnly: true)
    }

    private static func score(_ value: PlacementProposal, _ objective: PlacementObjective) -> [UInt64] {
        let first = value.firstTokenNanoseconds, decode = value.steadyDecodeNanosecondsPerToken ?? 0
        switch objective {
        case .firstToken: return [first, decode, value.totalRequestNanoseconds]
        case .steadyDecode: return [decode, first, value.totalRequestNanoseconds]
        case .totalRequest: return [value.totalRequestNanoseconds, first, decode]
        }
    }

    private static func memory(_ ledgers: [PlacementMemory], weights: [UInt64], phase: PlacementPhase,
                               request: PlacementRequest) throws -> [PlacementMemoryAssessment] {
        guard ledgers.count == 2 else { throw PlacementError.invalid("two memory ledgers required") }
        return try (0..<2).map { rank in
            let ledger = ledgers[rank], node = request.nodes[rank]
            guard PlacementMath.digest(ledger.evidenceSHA256) else { throw PlacementError.invalid("memory evidence identity") }
            let live = try PlacementMath.sum(ledger.charges)
            let required = try PlacementMath.sum([weights[rank], live, node.minimumFreeBytes, node.guardBytes])
            guard required <= node.actualAvailableBytes else {
                throw PlacementError.memory(rank: rank, required: required, available: node.actualAvailableBytes)
            }
            return .init(rank: rank, phase: phase, weightBytes: weights[rank], additionalLiveBytes: live,
                         minimumFreeBytes: node.minimumFreeBytes, guardBytes: node.guardBytes,
                         requiredAvailableBytes: required, observedAvailableBytes: node.actualAvailableBytes,
                         memoryEvidenceSHA256: ledger.evidenceSHA256, observationEvidenceSHA256: node.evidenceSHA256)
        }
    }

    private static func assess(_ candidate: PlacementCandidate, request: PlacementRequest,
                               costs: PlacementCostLookup) throws -> PlacementProposal {
        guard PlacementMath.name(candidate.id), PlacementMath.digest(candidate.adapterRecipeSHA256) else {
            throw PlacementError.invalid("candidate identity")
        }
        let prefillShape = try PlacementValidation.shape(candidate.prefillLayout, request: request)
        let decodeShape = try PlacementValidation.shape(candidate.decodeLayout, request: request)
        var boundCosts = costs
        boundCosts.phasePlacements = [.prefill: prefillShape.assignments, .decode: decodeShape.assignments,
                                     .transition: prefillShape.assignments]
        try PlacementValidation.graph(candidate.prefill, phase: .prefill, steps: request.workload.prefillSteps, shape: prefillShape)
        try PlacementValidation.graph(candidate.decode, phase: .decode, steps: request.workload.decodeSteps, shape: decodeShape)
        var assessments = try memory(candidate.prefillMemory, weights: prefillShape.weightBytes, phase: .prefill, request: request)
        assessments += try memory(candidate.decodeMemory, weights: decodeShape.weightBytes, phase: .decode, request: request)
        let prefill = try PlacementScheduling.schedule(candidate.prefill, phase: .prefill, costs: boundCosts)
        let decode = try PlacementScheduling.schedule(candidate.decode, phase: .decode, costs: boundCosts)
        let transition = try PlacementHandoff.assess(candidate, request: request, prefill: prefillShape, decode: decodeShape, costs: boundCosts)
        if let handoff = candidate.transition {
            let regions = Dictionary(uniqueKeysWithValues: request.model.weights.map { ($0.id, $0.bytes) })
            let peak = try (0..<2).map { rank in
                try PlacementMath.sum(prefillShape.weightIDs[rank].union(decodeShape.weightIDs[rank]).map { regions[$0]! })
            }
            assessments += try memory(handoff.memory, weights: peak, phase: .transition, request: request)
        }
        let decodePerToken: UInt64? = request.workload.decodeSteps > 0
            ? try PlacementMath.ceilingRatio(decode.nanoseconds, UInt64(request.workload.decodeSteps)) : nil
        return .init(candidateID: candidate.id, adapterRecipeSHA256: candidate.adapterRecipeSHA256,
                     prefillLayout: candidate.prefillLayout, decodeLayout: candidate.decodeLayout,
                     memory: assessments, prefill: prefill, transition: transition, decode: decode,
                     firstTokenNanoseconds: prefill.nanoseconds, transitionNanoseconds: transition.nanoseconds,
                     steadyDecodeNanosecondsPerToken: decodePerToken,
                     totalRequestNanoseconds: try PlacementMath.sum([prefill.nanoseconds, transition.nanoseconds, decode.nanoseconds]))
    }
}

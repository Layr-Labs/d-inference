import Foundation

enum PlacementHandoff {
    static func assess(_ candidate: PlacementCandidate, request: PlacementRequest,
                       prefill: PlacementShape, decode: PlacementShape,
                       costs: PlacementCostLookup) throws -> PlacementSchedule {
        guard let handoff = candidate.transition else {
            guard candidate.prefillLayout == candidate.decodeLayout else {
                throw PlacementError.missingMeasurement("changed placement needs an explicit handoff")
            }
            return .init(nanoseconds: 0, tasks: [])
        }
        guard PlacementMath.digest(handoff.evidenceSHA256), !handoff.tasks.isEmpty,
              handoff.memory.count == 2 else { throw PlacementError.invalid("handoff evidence") }
        try PlacementValidation.graph(handoff.tasks, phase: .transition, steps: 1, shape: prefill)
        var loaded = [Set<String>(), Set<String>()]
        var transferred = [UInt64(0), UInt64(0)]
        for task in handoff.tasks {
            switch task.work {
            case .loadWeights(let rank, let ids, _):
                guard loaded[rank].isDisjoint(with: ids) else { throw PlacementError.invalid("duplicate handoff weight load") }
                loaded[rank].formUnion(ids)
            case .transfer(let source, _, let bytes, _, _):
                guard (0...1).contains(source) else { throw PlacementError.invalid("handoff rank") }
                transferred[source] = try PlacementMath.sum([transferred[source], bytes])
            case .local: break
            }
        }
        for rank in 0..<2 {
            guard loaded[rank] == decode.weightIDs[rank].subtracting(prefill.weightIDs[rank]) else {
                throw PlacementError.missingMeasurement("exact missing weight loads for rank \(rank)")
            }
            let bothKV = try PlacementMath.sum([candidate.prefillMemory[rank].kvCacheBytes,
                                                candidate.decodeMemory[rank].kvCacheBytes])
            guard handoff.memory[rank].kvCacheBytes >= bothKV else {
                throw PlacementError.invalid("handoff must retain both declared KV allowances")
            }
        }
        guard transferred[0] >= handoff.kvBytes0to1, transferred[1] >= handoff.kvBytes1to0 else {
            throw PlacementError.missingMeasurement("KV handoff payload")
        }
        return try PlacementScheduling.schedule(handoff.tasks, phase: .transition, costs: costs)
    }
}

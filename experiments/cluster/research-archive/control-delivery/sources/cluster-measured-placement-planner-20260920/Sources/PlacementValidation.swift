import Foundation

struct PlacementShape {
    let assignments: [String: PlacementAssignment]
    let operatorRanks: [String: Set<Int>]
    let weightBytes: [UInt64]
    let weightIDs: [Set<String>]
    let operators: [PlacementOperator]
}

enum PlacementValidation {
    static func request(_ value: PlacementRequest) throws {
        let identity = value.identity, workload = value.workload
        guard PlacementMath.digest(identity.modelSHA256), PlacementMath.digest(identity.adapterSHA256),
              PlacementMath.name(identity.arithmeticProfile), PlacementMath.name(identity.transportProfile),
              identity.nodeIDs.count == 2, Set(identity.nodeIDs).count == 2,
              identity.nodeIDs.allSatisfy(PlacementMath.name), identity.nativeBuildSHA256.count == 2,
              identity.nativeBuildSHA256.allSatisfy(PlacementMath.digest),
              PlacementMath.digest(workload.sampleSHA256),
              (1...1_048_576).contains(workload.promptTokens),
              (1...1_048_576).contains(workload.prefillChunkTokens),
              workload.prefillChunkTokens <= workload.promptTokens,
              (1...4096).contains(workload.outputTokens), (1...1024).contains(workload.batchSize),
              workload.prefillSteps <= 4096,
              (1...64).contains(value.candidates.count),
              Set(value.candidates.map(\.id)).count == value.candidates.count,
              (1...4096).contains(value.model.operators.count), value.model.weights.count <= 131_072,
              value.nodes.count == 2, value.policy.maximumObservationAgeNanoseconds > 0 else {
            throw PlacementError.invalid("bounded model/workload/identity")
        }
        guard Set(value.model.operators.map(\.id)).count == value.model.operators.count,
              Set(value.model.weights.map(\.id)).count == value.model.weights.count,
              value.model.weights.allSatisfy({ PlacementMath.name($0.id) && $0.bytes > 0 }) else {
            throw PlacementError.invalid("unique operators and physical weight regions")
        }
        let known = Set(value.model.weights.map(\.id))
        var referenced = Set<String>()
        for op in value.model.operators {
            let references = op.fixedWeightIDs + op.expertWeightIDs.flatMap { $0 }
            guard PlacementMath.name(op.id), op.expertWeightIDs.count <= 16_384,
                  references.count <= 131_072, references.allSatisfy({ known.contains($0) }),
                  Set(references).count == references.count,
                  op.expertWeightIDs.allSatisfy({ !$0.isEmpty }) else {
                throw PlacementError.invalid("operator weight geometry")
            }
            referenced.formUnion(references)
        }
        guard referenced == known,
              value.candidates.reduce(0, { $0 + $1.prefill.count + $1.decode.count + ($1.transition?.tasks.count ?? 0) }) <= 32_768 else {
            throw PlacementError.invalid("unused weight regions or total task bound")
        }
        for rank in 0..<2 {
            let node = value.nodes[rank]
            guard node.nodeID == identity.nodeIDs[rank], PlacementMath.digest(node.evidenceSHA256),
                  node.actualAvailableBytes > 0, node.minimumFreeBytes > 0,
                  node.ageNanoseconds <= value.policy.maximumObservationAgeNanoseconds,
                  (!value.policy.requireACPower || node.onACPower),
                  node.pressureLevel == value.policy.requiredPressureLevel,
                  node.swapBytes <= value.policy.maximumSwapBytes else {
                throw PlacementError.invalid("stale or inadmissible node observation at rank \(rank)")
            }
        }
    }

    static func shape(_ layout: PlacementLayout, request: PlacementRequest) throws -> PlacementShape {
        var assignments: [String: PlacementAssignment] = [:]
        let operators = request.model.operators
        switch layout {
        case .singleNode(let rank):
            guard (0...1).contains(rank) else { throw PlacementError.invalid("single node rank") }
            for op in operators { assignments[op.id] = .node(rank) }
        case .pipeline(let cut):
            guard cut > 0, cut < operators.count else { throw PlacementError.invalid("pipeline cut") }
            for (index, op) in operators.enumerated() { assignments[op.id] = .node(index < cut ? 0 : 1) }
        case .wholeExperts(let placements):
            guard Set(placements.keys) == Set(operators.map(\.id)) else { throw PlacementError.invalid("incomplete operator placement") }
            assignments = placements
        }
        var weightIDs = [Set<String>(), Set<String>()]
        var ranks: [String: Set<Int>] = [:]
        for op in operators {
            guard let assignment = assignments[op.id] else { throw PlacementError.invalid("operator omitted") }
            switch assignment {
            case .node(let rank):
                guard (0...1).contains(rank) else { throw PlacementError.invalid("operator rank") }
                weightIDs[rank].formUnion(op.fixedWeightIDs + op.expertWeightIDs.flatMap { $0 })
                ranks[op.id] = [rank]
            case .replicated:
                for rank in 0..<2 { weightIDs[rank].formUnion(op.fixedWeightIDs + op.expertWeightIDs.flatMap { $0 }) }
                ranks[op.id] = [0, 1]
            case .wholeExperts(let ownership):
                guard !op.expertWeightIDs.isEmpty, ownership.count == 2 else { throw PlacementError.invalid("whole-expert geometry") }
                let all = ownership.flatMap { $0 }
                guard all.count == op.expertWeightIDs.count, Set(all) == Set(op.expertWeightIDs.indices) else {
                    throw PlacementError.invalid("each expert must have one owner")
                }
                var active = Set<Int>()
                for rank in 0..<2 {
                    weightIDs[rank].formUnion(op.fixedWeightIDs)
                    for expert in ownership[rank] { weightIDs[rank].formUnion(op.expertWeightIDs[expert]) }
                    if !ownership[rank].isEmpty || !op.fixedWeightIDs.isEmpty { active.insert(rank) }
                }
                ranks[op.id] = active
            }
        }
        let bytes = Dictionary(uniqueKeysWithValues: request.model.weights.map { ($0.id, $0.bytes) })
        let totals = try weightIDs.map { ids in try PlacementMath.sum(ids.map { bytes[$0]! }) }
        return .init(assignments: assignments, operatorRanks: ranks, weightBytes: totals,
                     weightIDs: weightIDs, operators: operators)
    }

    static func graph(_ tasks: [PlacementTask], phase: PlacementPhase, steps: Int, shape: PlacementShape) throws {
        func localRank(_ work: PlacementTaskWork) -> Int? {
            switch work {
            case .local(let rank, _, _), .loadWeights(let rank, _, _): return rank
            case .transfer: return nil
            }
        }
        guard tasks.count <= 4096, Set(tasks.map(\.id)).count == tasks.count else { throw PlacementError.invalid("bounded unique tasks") }
        if steps == 0 {
            guard tasks.isEmpty else { throw PlacementError.invalid("unexpected decode work") }
            return
        }
        guard !tasks.isEmpty else { throw PlacementError.invalid("empty required phase") }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var coverage: [Int: [String: Set<Int>]] = [:]
        for task in tasks {
            guard PlacementMath.name(task.id), (0..<steps).contains(task.step),
                  task.dependencies.count <= 64, Set(task.dependencies).count == task.dependencies.count,
                  task.dependencies.allSatisfy({ byID[$0] != nil && $0 != task.id }) else {
                throw PlacementError.invalid("task dependencies or position")
            }
            if case .local(let rank, let ops, _) = task.work {
                guard (0...1).contains(rank), (!ops.isEmpty || phase == .transition), ops.count <= 4096, Set(ops).count == ops.count else {
                    throw PlacementError.invalid("local task operator geometry")
                }
                for op in ops {
                    guard shape.operatorRanks[op]?.contains(rank) == true,
                          coverage[task.step]?[op]?.contains(rank) != true else {
                        throw PlacementError.invalid("missing, duplicate or wrong-rank local work")
                    }
                    coverage[task.step, default: [:]][op, default: []].insert(rank)
                }
            }
            if case .loadWeights(let rank, let weights, _) = task.work {
                guard phase == .transition, (0...1).contains(rank), !weights.isEmpty,
                      weights.count <= 131_072, Set(weights).count == weights.count else {
                    throw PlacementError.invalid("weight load scope")
                }
            }
            // Cross-node dependencies must contain a measured transport task;
            // a bare edge is never treated as a free data/control transfer.
            for parentID in task.dependencies {
                let parent = byID[parentID]!
                guard parent.step <= task.step else { throw PlacementError.invalid("future-step dependency") }
                if let a = localRank(parent.work), let b = localRank(task.work), a != b {
                    throw PlacementError.invalid("unmeasured cross-node edge")
                }
                if let rank = localRank(parent.work),
                   case .transfer(let source, _, _, _, _) = task.work, rank != source {
                    throw PlacementError.invalid("transfer source dependency")
                }
                if case .transfer(_, let destination, _, _, _) = parent.work,
                   let rank = localRank(task.work), destination != rank {
                    throw PlacementError.invalid("transfer destination dependency")
                }
            }
        }
        if phase == .transition { return }
        for step in 0..<steps {
            var expected: [String: Set<Int>] = [:]
            for op in shape.operators {
                let kind = phase == .prefill ? op.prefillCoverage : op.decodeCoverage
                if kind == .everyStep || (kind == .firstStep && step == 0) || (kind == .finalStep && step == steps - 1) {
                    expected[op.id] = shape.operatorRanks[op.id]
                }
            }
            guard (coverage[step] ?? [:]) == expected else { throw PlacementError.invalid("incomplete per-step operator coverage") }
        }
    }
}

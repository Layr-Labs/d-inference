import Foundation

enum FixtureFailure: Error { case assertion(String) }
func require(_ value: Bool, _ message: String) throws {
    guard value else { throw FixtureFailure.assertion(message) }
}
func mustThrow(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw FixtureFailure.assertion("expected refusal")
}

// Test-only Codable edits avoid giving the immutable production input values
// mutation APIs. Every fixture and nanosecond below is synthetic, not a cohort.
func replacing<T: Codable>(_ value: T, _ key: String, _ replacement: Any) throws -> T {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    object[key] = replacement
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

struct PlacementFixture {
    var request: PlacementRequest
    var measurements: PlacementMeasurements
    static let digest = String(repeating: "a", count: 64)

    var context: PlacementMeasurementContext {
        .init(identity: request.identity, workload: request.workload, costBasis: .median,
              evidenceSHA256: Self.digest, sampleCount: 3)
    }
    func result(_ objective: PlacementObjective = .totalRequest) throws -> PlacementReport {
        try MeasuredPlacementPlanner.plan(request, measurements: measurements, objective: objective)
    }
    mutating func candidates(_ values: [PlacementCandidate]) {
        request = .init(identity: request.identity, workload: request.workload, model: request.model,
                        nodes: request.nodes, policy: request.policy, candidates: values)
    }
    mutating func changeNode(_ rank: Int, _ key: String, _ value: Any) throws {
        var nodes = request.nodes
        nodes[rank] = try replacing(nodes[rank], key, value)
        request = try replacing(request, "nodes", object(nodes))
    }
    mutating func changeLocal(_ index: Int, _ key: String, _ value: Any) throws {
        var values = measurements.local
        values[index] = try replacing(values[index], key, value)
        measurements = .init(local: values, links: measurements.links)
    }
    func local(_ id: String, phase: PlacementPhase, step: Int, rank: Int,
               operators: [String], placements: [String: PlacementAssignment], duration: UInt64,
               load: Bool = false, host: Bool = false) -> PlacementLocalMeasurement {
        .init(id: id, context: context, phase: phase, step: step, rank: rank,
              operators: operators, isWeightLoad: load, operatorPlacements: placements,
              resources: [host ? .host(rank) : .compute(rank)], nanoseconds: duration)
    }
    static func memory(kv: UInt64 = 10) -> PlacementMemory {
        .init(evidenceSHA256: digest, kvCacheBytes: kv, activationPeakBytes: 20,
              workspacePeakBytes: 30, hostStagingBytes: 40, nativeStagingBytes: 50, otherRetainedBytes: 0)
    }
    static func pipeline() -> Self {
        let identity = PlacementIdentity(modelSHA256: digest, adapterSHA256: digest,
            arithmeticProfile: "synthetic-exact-v1", transportProfile: "diagnostic-unprotected/fixture-v1",
            nodeIDs: ["node-a", "node-b"], nativeBuildSHA256: [digest, digest])
        let workload = PlacementWorkload(sampleSHA256: digest, promptTokens: 2,
            prefillChunkTokens: 1, outputTokens: 3, batchSize: 1)
        let model = PlacementModel(weights: [.init(id: "wa", bytes: 100), .init(id: "wb", bytes: 200)],
            operators: ["a", "b"].map { .init(id: $0, fixedWeightIDs: ["w" + $0],
                expertWeightIDs: [], prefillCoverage: .everyStep, decodeCoverage: .everyStep) })
        let nodes = identity.nodeIDs.map { PlacementNodeObservation(nodeID: $0, evidenceSHA256: digest,
            actualAvailableBytes: 10_000, minimumFreeBytes: 100, guardBytes: 20,
            ageNanoseconds: 0, onACPower: true, pressureLevel: 1, swapBytes: 0) }
        var value = Self(request: .init(identity: identity, workload: workload, model: model, nodes: nodes,
            policy: .init(maximumObservationAgeNanoseconds: 1_000, requiredPressureLevel: 1,
                          requireACPower: true, maximumSwapBytes: 0, costBasis: .median), candidates: []),
            measurements: .init(local: [], links: []))
        var local = [PlacementLocalMeasurement]()
        func phase(_ phase: PlacementPhase) -> [PlacementTask] {
            var tasks = [PlacementTask]()
            for step in 0..<2 {
                let prefix = phase.rawValue + String(step)
                for (op, rank, duration) in [("a", 0, UInt64(10)), ("b", 1, UInt64(20))] {
                    local.append(value.local(prefix + op, phase: phase, step: step, rank: rank,
                        operators: [op], placements: [op: .node(rank)], duration: duration))
                }
                tasks += [
                    .init(id: prefix + "a", step: step, dependencies: [],
                          work: .local(rank: 0, operators: ["a"], measurementID: prefix + "a")),
                    .init(id: prefix + "forward", step: step, dependencies: [prefix + "a"],
                          work: .transfer(source: 0, destination: 1, plaintextBytes: 1, records: 1, measurementID: "forward")),
                    .init(id: prefix + "b", step: step, dependencies: [prefix + "forward"],
                          work: .local(rank: 1, operators: ["b"], measurementID: prefix + "b")),
                    .init(id: prefix + "ack", step: step, dependencies: [prefix + "b"],
                          work: .transfer(source: 1, destination: 0, plaintextBytes: 1, records: 1, measurementID: "reverse"))]
            }
            return tasks
        }
        let prefill = phase(.prefill), decode = phase(.decode)
        let links = [0, 1].map { source in PlacementLinkMeasurement(
            id: source == 0 ? "forward" : "reverse", context: value.context,
            source: source, destination: 1 - source, minimumPlaintextBytes: 1, maximumPlaintextBytes: 64,
            maximumPlaintextBytesPerRecord: 64, wireOverheadBytesPerRecord: 0,
            minimumRecords: 1, maximumRecords: 4, latencyNanosecondsPerRecord: 2,
            effectiveWireBytesPerSecond: 1_000_000_000, encryption: .unprotectedDiagnostic,
            fitMarginNanoseconds: 0) }
        value.measurements = .init(local: local, links: links)
        value.candidates([.init(id: "pipeline", adapterRecipeSHA256: digest,
            prefillLayout: .pipeline(cut: 1), decodeLayout: .pipeline(cut: 1),
            prefillMemory: [memory(), memory()], decodeMemory: [memory(), memory()],
            transition: nil, prefill: prefill, decode: decode)])
        return value
    }

    mutating func addSoloDecode() {
        let base = request.candidates[0]
        var local = measurements.local, decode = [PlacementTask]()
        for step in 0..<2 {
            let id = "solo-decode" + String(step)
            local.append(self.local(id, phase: .decode, step: step, rank: 1,
                operators: ["a", "b"], placements: ["a": .node(1), "b": .node(1)], duration: 21))
            decode.append(.init(id: id, step: step, dependencies: [],
                work: .local(rank: 1, operators: ["a", "b"], measurementID: id)))
        }
        local.append(self.local("load-wa", phase: .transition, step: 0, rank: 1,
            operators: ["wa"], placements: [:], duration: 50, load: true, host: true))
        local.append(self.local("joined", phase: .transition, step: 0, rank: 1,
            operators: [], placements: [:], duration: 1, host: true))
        let handoff = PlacementTransition(evidenceSHA256: Self.digest, kvBytes0to1: 5, kvBytes1to0: 0,
            memory: [Self.memory(kv: 20), Self.memory(kv: 20)], tasks: [
                .init(id: "load-wa", step: 0, dependencies: [],
                      work: .loadWeights(rank: 1, weightIDs: ["wa"], measurementID: "load-wa")),
                .init(id: "kv", step: 0, dependencies: [],
                      work: .transfer(source: 0, destination: 1, plaintextBytes: 5, records: 1, measurementID: "forward")),
                .init(id: "joined", step: 0, dependencies: ["load-wa", "kv"],
                      work: .local(rank: 1, operators: [], measurementID: "joined"))])
        measurements = .init(local: local, links: measurements.links)
        candidates(request.candidates + [.init(id: "phase-change", adapterRecipeSHA256: Self.digest,
            prefillLayout: base.prefillLayout, decodeLayout: .singleNode(1),
            prefillMemory: base.prefillMemory, decodeMemory: base.decodeMemory,
            transition: handoff, prefill: base.prefill, decode: decode)])
    }
}

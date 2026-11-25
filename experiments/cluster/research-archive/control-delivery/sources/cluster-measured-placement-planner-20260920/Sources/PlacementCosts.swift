import Foundation

struct PlacementTaskCost {
    let nanoseconds: UInt64
    let resources: Set<PlacementResource>
    let measurementID: String
    let evidenceSHA256: String
    let components: [String: UInt64]
}

struct PlacementCostLookup {
    let local: [String: PlacementLocalMeasurement]
    let links: [String: PlacementLinkMeasurement]
    let request: PlacementRequest
    var phasePlacements: [PlacementPhase: [String: PlacementAssignment]] = [:]

    init(_ measurements: PlacementMeasurements, request: PlacementRequest) throws {
        guard measurements.local.count + measurements.links.count <= 8192 else {
            throw PlacementError.invalid("calibration count")
        }
        var local: [String: PlacementLocalMeasurement] = [:]
        var links: [String: PlacementLinkMeasurement] = [:]
        for item in measurements.local {
            guard PlacementMath.name(item.id), local[item.id] == nil else { throw PlacementError.invalid("duplicate local calibration") }
            local[item.id] = item
        }
        for item in measurements.links {
            guard PlacementMath.name(item.id), links[item.id] == nil, local[item.id] == nil else { throw PlacementError.invalid("duplicate link calibration") }
            links[item.id] = item
        }
        self.local = local; self.links = links; self.request = request
    }

    func context(_ value: PlacementMeasurementContext) throws {
        guard value.identity == request.identity, value.workload == request.workload,
              value.costBasis == request.policy.costBasis,
              PlacementMath.digest(value.evidenceSHA256), (1...1_000_000).contains(value.sampleCount) else {
            throw PlacementError.mismatch("exact identity/workload/basis/evidence")
        }
    }

    func cost(_ task: PlacementTask, phase: PlacementPhase) throws -> PlacementTaskCost {
        switch task.work {
        case .local(let rank, let operators, let measurementID):
            return try localCost(rank: rank, items: operators, id: measurementID, phase: phase, step: task.step, weightLoad: false)
        case .loadWeights(let rank, let weights, let measurementID):
            return try localCost(rank: rank, items: weights, id: measurementID, phase: phase, step: task.step, weightLoad: true)
        case .transfer(let source, let destination, let bytes, let records, let measurementID):
            return try linkCost(source: source, destination: destination, bytes: bytes, records: records, measurementID: measurementID)
        }
    }

    private func localCost(rank: Int, items: [String], id measurementID: String,
                           phase: PlacementPhase, step: Int, weightLoad: Bool) throws -> PlacementTaskCost {
            guard let value = local[measurementID] else { throw PlacementError.missingMeasurement(measurementID) }
            try context(value.context)
            guard (0...1).contains(rank), value.rank == rank, value.operators == items, value.phase == phase,
                  value.step == step, value.isWeightLoad == weightLoad, value.nanoseconds > 0,
                  value.nanoseconds <= 3_600_000_000_000 else { throw PlacementError.mismatch(measurementID) }
            var expected: [String: PlacementAssignment] = [:]
            if !weightLoad {
                for item in items {
                    guard let assignment = phasePlacements[phase]?[item] else { throw PlacementError.invalid("measurement placement unavailable") }
                    expected[item] = assignment
                }
            }
            guard value.operatorPlacements == expected else { throw PlacementError.mismatch("operator/expert ownership: " + measurementID) }
            let resources = Set(value.resources)
            let allowed: Set<PlacementResource> = [.compute(rank), .host(rank)]
            guard !resources.isEmpty, resources.isSubset(of: allowed), resources.count == value.resources.count else {
                throw PlacementError.invalid("local resource declaration")
            }
            return .init(nanoseconds: value.nanoseconds, resources: resources, measurementID: measurementID,
                         evidenceSHA256: value.context.evidenceSHA256, components: ["measuredLocal": value.nanoseconds])
    }

    private func linkCost(source: Int, destination: Int, bytes: UInt64, records: UInt64,
                          measurementID: String) throws -> PlacementTaskCost {
            guard let value = links[measurementID] else { throw PlacementError.missingMeasurement(measurementID) }
            try context(value.context)
            guard value.source == source, value.destination == destination,
                  source != destination, (0...1).contains(source), (0...1).contains(destination),
                  value.minimumPlaintextBytes > 0, value.minimumPlaintextBytes <= value.maximumPlaintextBytes,
                  bytes >= value.minimumPlaintextBytes, bytes <= value.maximumPlaintextBytes,
                  bytes <= 268_435_456, value.maximumPlaintextBytesPerRecord > 0,
                  value.minimumRecords > 0, value.maximumRecords <= 1024,
                  records >= value.minimumRecords, records <= value.maximumRecords,
                  records >= (try PlacementMath.ceilingRatio(bytes, value.maximumPlaintextBytesPerRecord)) else {
                throw PlacementError.mismatch("link measurement domain: " + measurementID)
            }
            let wireBytes = try PlacementMath.sum([bytes, PlacementMath.multiply(records, value.wireOverheadBytesPerRecord)])
            let latency = try PlacementMath.multiply(records, value.latencyNanosecondsPerRecord)
            let wire = try PlacementMath.bytesTime(wireBytes, rate: value.effectiveWireBytesPerSecond)
            var seal: UInt64 = 0, open: UInt64 = 0, fixed: UInt64 = 0
            switch value.encryption {
            case .unprotectedDiagnostic:
                guard request.identity.transportProfile.hasPrefix("diagnostic-unprotected/") else {
                    throw PlacementError.mismatch("missing authenticated encryption measurements")
                }
            case .authenticated(let sealRate, let openRate, let fixedRecord):
                guard request.identity.transportProfile.hasPrefix("authenticated/") else {
                    throw PlacementError.mismatch("transport protection profile")
                }
                seal = try PlacementMath.bytesTime(bytes, rate: sealRate)
                open = try PlacementMath.bytesTime(bytes, rate: openRate)
                fixed = try PlacementMath.multiply(records, fixedRecord)
            }
            let components = ["wire": wire, "latency": latency, "seal": seal, "open": open,
                              "recordCryptoFixed": fixed, "measuredFitMargin": value.fitMarginNanoseconds]
            let total = try PlacementMath.sum(Array(components.values))
            guard total > 0, total <= 3_600_000_000_000 else { throw PlacementError.invalid("transfer duration") }
            return .init(nanoseconds: total, resources: [.link, .host(source), .host(destination)],
                         measurementID: measurementID, evidenceSHA256: value.context.evidenceSHA256,
                         components: components)
    }
}

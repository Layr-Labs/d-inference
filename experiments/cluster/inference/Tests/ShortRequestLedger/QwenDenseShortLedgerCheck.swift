import Foundation

struct QwenDenseShortLedgerFixtureInputs: Decodable {
    struct Input: Decodable {
        let configuration: Data, manifest: Data
        let canonicalTensors: [QwenDenseCanonicalTensor]
    }
    let nine: Input, twentySeven: Input
}

struct QwenDenseShortLedgerCheckResult: Encodable {
    let kind = "qwen_dense_short_ledger_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    var acceptedChecks: Int { accepted.count }
    var rejectedChecks: Int { rejected.count }
    let allocatorBoundsAreInvented = true, runtimeExecutionAuthorized = false
    let modelTensorPayloadRead = false, currentResourceObservationPerformed = false
    let nativeModelExecutionPerformed = false
    enum CodingKeys: String, CodingKey {
        case kind, schemaVersion, accepted, rejected, acceptedChecks, rejectedChecks
        case allocatorBoundsAreInvented, runtimeExecutionAuthorized, modelTensorPayloadRead
        case currentResourceObservationPerformed, nativeModelExecutionPerformed
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(accepted, forKey: .accepted); try c.encode(rejected, forKey: .rejected)
        try c.encode(acceptedChecks, forKey: .acceptedChecks); try c.encode(rejectedChecks, forKey: .rejectedChecks)
        try c.encode(allocatorBoundsAreInvented, forKey: .allocatorBoundsAreInvented)
        try c.encode(runtimeExecutionAuthorized, forKey: .runtimeExecutionAuthorized)
        try c.encode(modelTensorPayloadRead, forKey: .modelTensorPayloadRead)
        try c.encode(currentResourceObservationPerformed, forKey: .currentResourceObservationPerformed)
        try c.encode(nativeModelExecutionPerformed, forKey: .nativeModelExecutionPerformed)
    }
}

func checkQwenDenseShortLedger(_ inputs: QwenDenseShortLedgerFixtureInputs) throws -> QwenDenseShortLedgerCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ label: String, _ value: Bool) throws {
        guard value else { throw QwenDenseProfileError("Short ledger fixture failed: " + label) }
        accepted.append(label)
    }
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw QwenDenseProfileError("Short ledger fixture admitted: " + label)
    }
    func profile(_ input: QwenDenseShortLedgerFixtureInputs.Input, artifact: String) throws -> QwenRegisteredDenseModelProfile {
        try .admit(configuration: input.configuration, manifest: input.manifest,
            expectedArtifactAggregateSHA256: artifact, canonicalTensors: input.canonicalTensors)
    }
    let nine = try profile(inputs.nine, artifact: "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b")
    let large = try profile(inputs.twentySeven, artifact: "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463")
    func request(prompt: [Int] = [1, 2, 3], chunk: Int = 2, teacher: [Int] = [4], vocabulary: Int = 248320,
                 uuid: String = "10000000-0000-0000-0000-000000000001") throws -> QwenLayerStageRecordedRequest {
        try .init(request: .init(requestID: UUID(uuidString: uuid)!, promptCount: prompt.count,
            chunkSize: chunk, outputCount: teacher.count + 1), vocabularySize: vocabulary, prompt: prompt, teacher: teacher)
    }
    let recorded = try request()
    for (index, p) in [nine, large].enumerated() {
        let label = p.model.rawValue, plan = try p.makePlanningPlan()
        var boundInputs: [Int] = []
        let full = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
            scope: .fullReference, allocationFootprintUpperBound: { boundInputs.append($0); return $0 })
        let pair = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
            scope: .sequentialStagePair, allocationFootprintUpperBound: { $0 })
        let expectedFrontiers = index == 0 ? [51_576_864, 51_609_632, 51_642_400] : [154_075_200, 154_140_736, 154_206_272]
        try require(label + " exact frontiers and capacity5", full.stateOwners[0].frontiers.map(\.logicalBytes) == expectedFrontiers &&
            full.nativeCapacityStateBytes == [51_675_168, 154_271_808][index] && full.maximumTokens == 5)
        try require(label + " state shapes and native dtype", full.stateOwners[0].frontiers[2].kvShape == [1, 4, 4, 256] &&
            full.stateOwners[0].frontiers[2].ssmShape == [1, index == 0 ? 32 : 48, 128, 128] &&
            full.stateOwners[0].frontiers[2].convolutionShape == [1, 3, index == 0 ? 8192 : 10240] &&
            full.stateOwners[0].frontiers[2].kvDType == "bfloat16")
        try require(label + " conserved pair ownership", pair.stateOwners.map(\.lowerLayer) == [0, p.geometry.layers / 2] &&
            pair.stateOwners.map(\.upperLayer) == [p.geometry.layers / 2, p.geometry.layers] &&
            pair.stateOwners.map({ $0.frontiers[2].componentCount }) == [index == 0 ? 36 : 72, index == 0 ? 36 : 72] &&
            pair.nativeCapacityStateBytes == full.nativeCapacityStateBytes &&
            zip(pair.stateOwners[0].frontiers, pair.stateOwners[1].frontiers).map({ $0.0.logicalBytes + $0.1.logicalBytes }) == expectedFrontiers)
        try require(label + " fresh short named formula", full.namedStateBudget.maximumTokens == 5 &&
            full.namedStateBudget.chunkSize == 2 && full.namedStateBudget.conservativeStateAndBoundaryBytes == [160_563_232, 474_562_624][index])
        try require(label + " independently derived fusion arrays", full.fusionReplacementLogicalBytes == [683_016_192, 2_278_195_200][index] &&
            full.nativeAllowances.filter({ $0.category == "fusion" }).count == [72, 144][index] &&
            full.nativeAllowances.filter({ $0.category == "fusion" }).map(\.logicalBytesPerArray).max() == [25_296_896, 42_188_800][index])
        try require(label + " exact invented-bound Q vectors", full.forwardReserveBytes == [873_827_368, 2_826_550_344][index] &&
            pair.forwardReserveBytes == [876_441_640, 2_829_197_384][index])
        try require(label + " CPU baseline retained through pair", full.cpuEvidence.logicalBytes == [5_076_992, 6_125_568][index] &&
            pair.cpuEvidence.logicalBytes == [7_625_728, 8_690_688][index] &&
            pair.cpuEvidence.baselineNativeRowBytes == 993_280 && pair.cpuEvidence.candidateFloatRowBytes == 1_986_560 &&
            pair.cpuEvidence.retainedRawStateHistoryBytes == 0)
        try require(label + " distinct scope identity", full.fingerprint != pair.fingerprint &&
            full.recordedRequestFingerprint == recorded.fingerprint && full.modelProfileFingerprint == p.fingerprint &&
            full.planFingerprint == plan.fingerprint && full.scope == .fullReference && pair.scope == .sequentialStagePair)
        try require(label + " individually bounded arrays", boundInputs == full.nativeAllowances.map(\.logicalBytesPerArray))
        let rounded = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
            scope: .fullReference, allocationFootprintUpperBound: { try QwenLongPrefillCheckedBytes.sum([$0, 16]) })
        let added = try QwenLongPrefillCheckedBytes.product([16, QwenLongPrefillCheckedBytes.sum(full.nativeAllowances.map(\.instances))])
        try require(label + " per-array padding not aggregate rounding", rounded.forwardReserveBytes == full.forwardReserveBytes + added &&
            rounded.fingerprint != full.fingerprint)
        try require(label + " no execution or peak assertion", !full.runtimeExecutionAuthorized && !full.isWholeProcessMemoryBound &&
            !full.allocatorProvenanceIndependentlyVerified && !full.unknownNativeScratchIncluded && !full.weightsAndLoadHostCopiesIncluded)
        for altered in [try request(prompt: [4, 2, 3]), try request(teacher: [5]),
                        try request(uuid: "10000000-0000-0000-0000-000000000002")] {
            let other = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: altered,
                scope: .fullReference, allocationFootprintUpperBound: { $0 })
            try require(label + " changed history or UUID has new identity " + altered.fingerprint,
                other.fingerprint != full.fingerprint && other.recordedRequestFingerprint == altered.fingerprint &&
                other.forwardReserveBytes == full.forwardReserveBytes)
        }
        for altered in [try request(prompt: [1, 2]), try request(prompt: [1, 2, 3, 4]),
                        try request(chunk: 1), try request(chunk: 3), try request(teacher: []),
                        try request(teacher: [4, 5]), try request(vocabulary: 100)] {
            var calls = 0
            try reject(label + " wrong request " + altered.fingerprint) {
                _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: altered,
                    scope: .fullReference, allocationFootprintUpperBound: { calls += 1; return $0 })
            }
            guard calls == 0 else { throw QwenDenseProfileError("Wrong request reached allocator callback") }
        }
        for wrong in [-1, 0, 1] {
            try reject(label + " invalid allocator bound \(wrong)") {
                _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
                    scope: .fullReference, allocationFootprintUpperBound: { _ in wrong })
            }
        }
        try reject(label + " allocator one byte below array") {
            _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
                scope: .fullReference, allocationFootprintUpperBound: { $0 - 1 })
        }
        try reject(label + " allocation instance product overflow") {
            _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
                scope: .fullReference, allocationFootprintUpperBound: { _ in Int.max })
        }
        try reject(label + " allocation total sum overflow") {
            _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
                scope: .fullReference, allocationFootprintUpperBound: { _ in Int.max / 512 })
        }
        enum Sentinel: Error { case allocation }
        var preserved = false
        do {
            _ = try QwenDenseShortRequestLedger.derive(profile: p, plan: plan, request: recorded,
                scope: .fullReference, allocationFootprintUpperBound: { _ in throw Sentinel.allocation })
        } catch Sentinel.allocation { preserved = true }
        try require(label + " original allocator error preserved", preserved)
    }
    var calls = 0
    for wrongPlan in [try large.makePlanningPlan(), try nine.makePlanningPlan(stageCut: 12)] {
        try reject("wrong model or nondefault Plan " + wrongPlan.fingerprint) {
            _ = try QwenDenseShortRequestLedger.derive(profile: nine, plan: wrongPlan, request: recorded,
                scope: .fullReference, allocationFootprintUpperBound: { calls += 1; return $0 })
        }
    }
    try require("wrong Plan never reaches allocator", calls == 0)
    for shape in [[], [0], [-1], [Int.max, 2], [1, 1, 1, 1, 1, 1]] {
        try reject("malformed or overflowing array shape " + String(describing: shape)) {
            var b = QwenDenseShortAllowanceBuilder()
            try b.append(category: "test", owner: "test", name: "array", shape: shape, elementBytes: 4, instances: 1, bound: { $0 })
        }
    }
    for count in [0, -1, 1025] {
        try reject("invalid instance count \(count)") {
            var b = QwenDenseShortAllowanceBuilder()
            try b.append(category: "test", owner: "test", name: "array", shape: [1], elementBytes: 4, instances: count, bound: { $0 })
        }
    }
    try reject("duplicate owner array identity") {
        var b = QwenDenseShortAllowanceBuilder()
        for _ in 0..<2 { try b.append(category: "test", owner: "test", name: "array", shape: [1], elementBytes: 4, instances: 1, bound: { $0 }) }
    }
    try reject("more than256 named allowances") {
        var b = QwenDenseShortAllowanceBuilder()
        for i in 0...256 { try b.append(category: "test", owner: "test", name: "array\(i)", shape: [1], elementBytes: 4, instances: 1, bound: { $0 }) }
    }
    for range in [(1, 16), (0, 15), (0, 36), (16, 16)] {
        try reject("invalid state owner range \(range.0)/\(range.1)") {
            _ = try QwenDenseShortStateLedger.owner(geometry: nine.geometry, name: "test", lower: range.0, upper: range.1)
        }
    }
    guard accepted.count == 31, rejected.count == 42 else {
        throw QwenDenseProfileError("Short fixture source count changed: \(accepted.count)/\(rejected.count)")
    }
    return .init(accepted: accepted, rejected: rejected)
}

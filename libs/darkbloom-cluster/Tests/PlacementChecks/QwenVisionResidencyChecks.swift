import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

struct QwenVisionBudgetFixture: Decodable {
    let configurationSHA256: String
    let tensors: [QwenDenseCanonicalTensor]
    var stored: [ClusterPlacementStoredTensor] {
        tensors.map { .init(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape) }
    }
    static func read(_ golden: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf:
            golden.deletingLastPathComponent().appendingPathComponent("Inputs/qwen27-vision-budget.json")))
    }
}

func checkQwenVisionResidency(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let fixture = try QwenVisionBudgetFixture.read(golden)
    var calls: [Int] = []
    let budget = try QwenVisionResidentBudget(configurationSHA256: fixture.configurationSHA256,
        tensors: fixture.tensors, allocationBound: { calls.append($0); return $0 + 16_384 })
    checks.require("Qwen27 media: exact333 tower arrays are bounded separately",
        calls.count == 333 && calls == fixture.tensors.map(\.byteCount)
            && budget.logicalBytes == 921_460_192 && budget.allocationBytes == 921_460_192 + 333 * 16_384)
    func refuses(_ label: String, _ tensors: [QwenDenseCanonicalTensor],
                 config: String? = nil, bound: (Int) throws -> Int = { $0 }) {
        checks.refuses("Qwen27 media: " + label, because: "vision resident") {
            _ = try QwenVisionResidentBudget(configurationSHA256: config ?? fixture.configurationSHA256,
                tensors: tensors, allocationBound: bound)
        }
    }
    refuses("missing visual array", Array(fixture.tensors.dropLast()))
    refuses("duplicate visual array", Array(fixture.tensors.dropLast()) + [fixture.tensors[0]])
    refuses("wrong configuration", fixture.tensors, config: String(repeating: "0", count: 64))
    refuses("allocator underestimate", fixture.tensors, bound: { $0 - 1 })
    refuses("allocator overflow", fixture.tensors, bound: { _ in Int.max })
    let first = fixture.tensors[0]
    refuses("same total wrong shape", [.init(name: first.name, shape: [first.byteCount / 2, 1],
        sourceDType: first.sourceDType, byteCount: first.byteCount)] + fixture.tensors.dropFirst())
    refuses("wrong storage dtype", [.init(name: first.name, shape: first.shape,
        sourceDType: "F16", byteCount: first.byteCount)] + fixture.tensors.dropFirst())

    let old = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored)
    let object = try JSONSerialization.jsonObject(with: old.encoded()) as! [String: Any]
    func modified(_ bytes: Int?) throws -> ClusterModelLayout {
        var result = object
        var tp = result["tensorParallel"] as! [String: Any]
        var family = tp["family"] as! [String: Any]
        family["additionalResidentBytes"] = bytes
        tp["family"] = family; result["tensorParallel"] = tp
        return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
    let unchanged = try modified(nil)
    checks.require("Qwen27 media: omitted resident supplement preserves exact legacy encoding",
        try old.encoded() == unchanged.encoded())
    for invalid in [-1, 0, Int.max, (1 << 50) + 1] {
        checks.refuses("Qwen27 media: invalid resident supplement \(invalid) rejects before planner arithmetic",
            because: "resident") { _ = try modified(invalid) }
    }
    // The complete request floor can be larger than the ordinary estimate;
    // resident bytes must still add on top rather than disappear inside max.
    let devices = try [SyntheticMac.idle(64).device("a"), SyntheticMac.idle(64).device("b")]
    func candidate(_ layout: ClusterModelLayout, mode: ClusterGenerationMode) throws -> ClusterPlacementCandidate {
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: mode == .tensorParallel ? [] : [30], mode: mode,
            prefillSchedule: .serial, layout: layout, policy: .init(), link: linkCosts(reductionMicroseconds: 45))
    }
    let charged = try modified(budget.allocationBytes)
    let baseTP = try candidate(old, mode: .tensorParallel), extraTP = try candidate(charged, mode: .tensorParallel)
    checks.require("Qwen27 media: every TP rank adds persistent tower outside request floors",
        zip(baseTP.ranks, extraTP.ranks).allSatisfy {
            $1.weightsBytes == $0.weightsBytes + budget.allocationBytes
                && $1.requestNeedBytes == $0.requestNeedBytes
                && $1.loadNeedBytes == $0.loadNeedBytes + 3 * budget.allocationBytes
                && $1.needBytes >= $0.needBytes + budget.allocationBytes
        })
    let basePipeline = try candidate(old, mode: .pipeline), extraPipeline = try candidate(charged, mode: .pipeline)
    checks.require("Qwen27 media: TP residency does not change pipeline ranks", basePipeline.ranks == extraPipeline.ranks)
    let enormous = try candidate(modified(96 * gib), mode: .tensorParallel)
    checks.require("Qwen27 media: extra residency participates in GPU and hardware fit",
        enormous.ranks.allSatisfy { !$0.withinGPUWorkingSet && $0.hardwareFits == false })

    let actual = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored + fixture.stored, tensorParallelAllocationBound: { $0 + 16_384 })
    checks.require("Qwen27 media: production metadata path supplies exact persistent budget",
        actual.tensorParallel?.family.additionalResidentBytes == budget.allocationBytes)
    checks.refuses("Qwen27 media: product layout refuses missing visual headers", because: "vision resident") {
        _ = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
            tensors: inputs.twentySeven.stored, tensorParallelAllocationBound: { $0 + 16_384 })
    }
    let nine = try ClusterPlacementLayouts.layout(configuration: inputs.nine.configuration,
        tensors: inputs.nine.stored, tensorParallelAllocationBound: { $0 + 16_384 })
    checks.require("Qwen27 media: other Qwen model has no new resident quote", nine.tensorParallel?.family.additionalResidentBytes == nil)
}

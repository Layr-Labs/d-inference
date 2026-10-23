import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

func checkBatchScopes(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let original = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored)
    // Fix a cut to compare the actual rank accounting, independent of a wider
    // request changing which placement the planner prefers.
    var object = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
    object["admittedCuts"] = [original.admittedCuts[original.admittedCuts.count / 2]]
    let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    let devices = try [SyntheticMac.idle(1024).device("a"), SyntheticMac.idle(1024).device("b")]
    func scope(charge: Int = 32 * gib, model: String? = nil) throws -> ClusterPlacementRequestScope {
        try .init(runtimeModelID: model ?? layout.runtimeModelID, artifactSHA256: layout.artifactSHA256,
            configurationSHA256: layout.configurationSHA256, promptTokens: 1024, outputTokens: 128,
            maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumContextTokens: 65536,
            requestChargeEveryRankBytes: charge)
    }
    let request = try scope()
    var serial = ClusterPlacementPolicy()
    serial.promptTokens = 1024; serial.outputTokens = 128; serial.modes = [.pipeline]; serial.schedules = [.serial]
    serial.leader = "a"
    try request.apply(to: &serial, layout: layout)
    let before = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: serial)
    let baseline = before.chosen!
    for width in [2, 4, 8] {
        var policy = serial
        let batch = try ClusterPlacementBatchScope(request: request, lanes: width)
        try batch.apply(to: &policy, layout: layout)
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        let chosen = result.chosen!
        checks.require("batch \(width): charges one complete state per lane on each actual rank",
            zip(baseline.ranks, chosen.ranks).allSatisfy { old, new in
                new.requestNeedBytes - old.requestNeedBytes == (width - 1) * request.requestChargeEveryRankBytes
                    && old.weightsBytes == new.weightsBytes && old.loadNeedBytes == new.loadNeedBytes
                    && old.transientBytes == new.transientBytes
            })
        checks.require("batch \(width): does not invent width times single-request speed",
            chosen.rested == baseline.rested && chosen.sustained == baseline.sustained)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    checks.require("singleton planning remains byte-identical after separate batch recommendations",
        try encoder.encode(ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: serial))
            == encoder.encode(before))
    for demand in [-1, 0, 1, 2, 3, 4, 5, 8, Int.max] {
        let expected = demand <= 1 ? [] : demand == 2 ? [2] : demand <= 4 ? [4, 2] : [8, 4, 2]
        checks.require("batch demand \(demand): bounded native candidates", ClusterPlacementBatchScope.candidateWidths(waitingRequests: demand) == expected)
    }
    for width in [Int.min, 0, 1, 3, 7, 9, Int.max] {
        checks.refuses("batch invalid width \(width)", because: "priced native") {
            _ = try ClusterPlacementBatchScope(request: request, lanes: width)
        }
    }
    for model in ["registered_gpt_oss_20b", "registered_mimo_v26_flash_mopd", ClusterGLMImageCandidate.runtimeModelID, "unknown"] {
        checks.refuses("batch \(model): no unpriced or GLM activation", because: "priced native") {
            _ = try ClusterPlacementBatchScope(request: scope(model: model), lanes: 2)
        }
    }
    checks.refuses("batch zero quote cannot be mistaken for free histories", because: "priced native") {
        _ = try ClusterPlacementBatchScope(request: scope(charge: 0), lanes: 2)
    }
    checks.refuses("batch checked product cannot exceed the protocol byte ceiling", because: "byte bound") {
        _ = try ClusterPlacementBatchScope(request: scope(charge: ClusterWorkerLimits.capacityBytes), lanes: 8)
    }
    checks.refuses("batch small whole-model quote cannot underprice owned layers", because: "every layer") {
        var policy = serial
        try ClusterPlacementBatchScope(request: scope(charge: 1), lanes: 8).apply(to: &policy, layout: layout)
    }
    checks.refuses("batch explicit speculative mode is not silently rewritten", because: "plain pipeline") {
        var policy = serial; policy.modes = [.pipelineMTP]
        try ClusterPlacementBatchScope(request: request, lanes: 2).apply(to: &policy, layout: layout)
    }
    checks.refuses("batch changed request cannot borrow the previous quote", because: "another model or request") {
        var policy = serial; policy.outputTokens = 129
        try ClusterPlacementBatchScope(request: request, lanes: 2).apply(to: &policy, layout: layout)
    }
    var tooWide = serial
    try ClusterPlacementBatchScope(request: request, lanes: 8).apply(to: &tooWide, layout: layout)
    let limited = try [SyntheticMac.idle(128).device("a"), SyntheticMac.idle(256).device("b")]
    checks.require("batch one smaller rank refuses the concurrent set, even when the peer fits",
        try ClusterPlacementPlanner.plan(devices: limited, layout: layout, policy: tooWide).chosen == nil)
}

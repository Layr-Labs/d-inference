import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Actual planner with constructed native ledgers and measured rate inputs.
/// The Runtime suite separately checks the real canonical budget derivation.
func checkTensorBatchScopes(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let original = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let layout = try executing(original, [.pipeline, .tensorParallel])
    let request = try ClusterPlacementRequestScope(runtimeModelID: layout.runtimeModelID,
        artifactSHA256: layout.artifactSHA256, configurationSHA256: layout.configurationSHA256,
        promptTokens: 1024, outputTokens: 128, maximumPromptTokens: 32768, maximumOutputTokens: 32768,
        maximumContextTokens: 65536, requestChargeEveryRankBytes: 4 * gib)
    func quote(_ lanes: Int, shared: Int = 80 * gib) throws -> ClusterPlacementTensorBatchQuote {
        let payload = max(512 * layout.tensorParallel!.family.partialBytesPerToken, lanes * 248320 * 4)
        return try .init(request: request, lanes: lanes, chunkTokens: 128, perLaneStateBytes: 4 * gib,
            sharedBytesExcludingCollectives: shared, allowance: .init(maximumContextTokens: 65536,
                maximumChunkTokens: 512, requestBytesExcludingCollectives: lanes * 4 * gib + shared,
                maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: payload + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }))
    }
    func policy(_ value: ClusterPlacementTensorBatchQuote?) throws -> ClusterPlacementPolicy {
        var p = ClusterPlacementPolicy(); p.promptTokens = request.promptTokens; p.outputTokens = request.outputTokens
        p.leader = "a"
        try ClusterPlacementBatchScope(request: request, lanes: value?.lanes ?? 2,
            tensorParallelQuote: value).apply(to: &p, layout: layout)
        return p
    }
    func devices(shard: Double, size: Double = 256) throws -> [ClusterPlacementDevice] {
        let speed = ClusterDeviceSpeed(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
                tensorShardPrefillTokensPerSecond: 1500, tensorShardDecodeTokensPerSecond: shard),
            sustained: nil, explanation: "constructed CPU rates")
        return try [SyntheticMac.idle(size).device("a", speed: speed), SyntheticMac.idle(size).device("b", speed: speed)]
    }
    let link = linkCosts(reductionMicroseconds: 1)
    let fast = try devices(shard: 200), slow = try devices(shard: 10)
    let q = try quote(2), p = try policy(q)
    let batch = try ClusterPlacementPlanner.plan(devices: fast, layout: layout, policy: p, link: link)
    checks.require("TP batch: exact priced TP competes and wins only with faster measured shard rates", batch.chosen?.mode == .tensorParallel)
    checks.require("TP batch: slower measured TP keeps a fitting pipeline", try ClusterPlacementPlanner.plan(devices: slow,
        layout: layout, policy: p, link: link).chosen?.mode == .pipeline)
    checks.require("TP batch: absent quote keeps the old pipeline-only batch scope", try ClusterPlacementPlanner.plan(devices: fast,
        layout: layout, policy: policy(nil), link: link).chosen?.mode == .pipeline)
    checks.require("TP batch: unmeasured reduction never selects TP", try ClusterPlacementPlanner.plan(devices: fast,
        layout: layout, policy: p).chosen?.mode != .tensorParallel)
    var blocked = p; blocked.admitsShape = { _, _, mode in mode != .tensorParallel }
    checks.require("TP batch: failed qualification shape still withholds TP", try ClusterPlacementPlanner.plan(devices: fast,
        layout: layout, policy: blocked, link: link).chosen?.mode == .pipeline)
    let two = try ClusterPlacementPlanner.evaluate(devices: fast, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: p, link: link)
    checks.require("TP batch: full native floor is a max, with loading headroom added only once",
        zip(two.ranks, fast).allSatisfy { $0.requestNeedBytes == q.allowance.reservedBytes + $1.profile.memory.loadingHeadroomBytes })
    for lanes in [2, 4, 8] {
        let value = try quote(lanes), policy = try policy(value)
        let candidate = try ClusterPlacementPlanner.evaluate(devices: fast, cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: layout, policy: policy, link: link)
        checks.require("TP batch \(lanes): prediction never multiplies single-request rates by width",
            candidate.rested == two.rested && candidate.sustained == two.sustained)
        checks.require("TP batch \(lanes): full native state floor covers both ranks",
            zip(candidate.ranks, fast).allSatisfy { $0.requestNeedBytes == value.allowance.reservedBytes + $1.profile.memory.loadingHeadroomBytes })
        checks.require("TP batch \(lanes): encode/decode preserves native ledger",
            try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(value)) == value)
        try value.requireRequest(promptTokens: 1024, outputTokens: 128, lanes: lanes, chunkTokens: 128)
        checks.refuses("TP batch \(lanes): changed chunk refuses", because: "original chunk") {
            try ClusterPlacementBatchScope(request: request, lanes: lanes, tensorParallelQuote: value).requireChunk(512, derived: false)
        }
    }
    let small = try [SyntheticMac.idle(64).device("a"), SyntheticMac.idle(256).device("b")]
    let rejected = try ClusterPlacementPlanner.evaluate(devices: small, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: p, link: link)
    checks.require("TP batch: one undersized Mac refuses even while its peer fits",
        !rejected.possible && rejected.ranks[0].hardwareFits == false && rejected.ranks[1].hardwareFits == true)
    for (name, mutate) in [
        ("width", { (x: inout [String: Any]) in x["lanes"] = 4 }),
        ("shared ledger", { (x: inout [String: Any]) in x["sharedBytesExcludingCollectives"] = 1 }),
        ("negative lane", { (x: inout [String: Any]) in x["perLaneStateBytes"] = -1 }),
        ("foreign model", { (x: inout [String: Any]) in var r = x["request"] as! [String: Any]; r["runtimeModelID"] = "registered_qwen35_9b"; x["request"] = r }),
        ("short LOAD context", { (x: inout [String: Any]) in var a = x["allowance"] as! [String: Any]; a["maximumContextTokens"] = 4096; x["allowance"] = a }),
        ("short LOAD chunk", { (x: inout [String: Any]) in var a = x["allowance"] as! [String: Any]; a["maximumChunkTokens"] = 128; x["allowance"] = a }),
    ] {
        checks.refuses("TP batch: decoded \(name) refuses", because: "tensor batch quote") {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: Any]
            mutate(&object); _ = try ClusterPlacementTensorBatchQuote.decode(JSONSerialization.data(withJSONObject: object))
        }
    }
    checks.refuses("TP batch: other width cannot borrow quote", because: "different requests or widths") {
        _ = try ClusterPlacementBatchScope(request: request, lanes: 8, tensorParallelQuote: q)
    }
    checks.refuses("TP batch: explicit MTP is not rewritten", because: "plain pipeline") {
        var incompatible = p; incompatible.modes = [.pipelineMTP]
        try ClusterPlacementBatchScope(request: request, lanes: 2, tensorParallelQuote: q).apply(to: &incompatible, layout: layout)
    }
}

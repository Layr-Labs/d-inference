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
    let noBatchReservation = try ClusterPlacementPlanner.evaluate(devices: fast, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: .init(), link: link)
    checks.require("TP batch: native request allowance coexists with complete load scratch on both ranks",
        zip(two.ranks, noBatchReservation.ranks).allSatisfy {
            $0.loadNeedBytes == $1.loadNeedBytes + q.allowance.reservedBytes
                && $0.needBytes >= $0.loadNeedBytes && $0.weightsBytes == $1.weightsBytes
        })
    checks.require("TP batch: simultaneous load is larger than the former alternate-peaks estimate",
        zip(two.ranks, noBatchReservation.ranks).allSatisfy {
            $0.needBytes > max($1.loadNeedBytes, $0.weightsBytes + $0.requestNeedBytes)
        })
    // Keep hardware identical and put live admissible bytes strictly between
    // the real two- and four-lane LOAD peaks. Both widths remain hardware-
    // possible; only two lanes may disturb the existing serving owner now.
    let fourQuote = try quote(4)
    let four = try ClusterPlacementPlanner.evaluate(devices: fast, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: policy(fourQuote), link: link)
    let available = (two.ranks[0].needBytes + four.ranks[0].needBytes) / 2
    let pressured = try [SyntheticMac(physicalGiB: 256, freeGiB: Double(available) / Double(gib),
        inactiveCacheGiB: 0).device("a", speed: fast[0].speed), fast[1]]
    let fitsTwo = try ClusterPlacementPlanner.evaluate(devices: pressured, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: p, link: link)
    let waitsFour = try ClusterPlacementPlanner.evaluate(devices: pressured, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: policy(fourQuote), link: link)
    checks.require("TP batch: lower width fits current pair when higher width only fits at rest",
        fitsTwo.ranks.allSatisfy { $0.fit == .now } && waitsFour.possible
            && waitsFour.ranks[0].fit != .now && waitsFour.ranks[1].fit == .now)
    // The native allocator also reserves the future request during LOAD.
    // Sufficient OS memory must not hide a smaller allocator ceiling.
    let largest = ([layout.ingress, layout.egress] + layout.layers.map(\.weights)).map(\.largestTensorBytes).max()!
    var allocatorObject = try JSONSerialization.jsonObject(with: fast[0].profile.encoded()) as! [String: Any]
    allocatorObject["allocatorLimitBytes"] = two.ranks[0].weightsBytes + largest
        + fast[0].profile.memory.allocatorHeadroomBytes + q.allowance.reservedBytes - 1
    let allocatorProfile = try ClusterDeviceProfile.decode(JSONSerialization.data(withJSONObject: allocatorObject))
    let allocatorBounded = try ClusterPlacementPlanner.evaluate(devices: [
        .init(label: "a", profile: allocatorProfile, speed: fast[0].speed), fast[1]], cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: p, link: link)
    checks.require("TP batch: allocator limit includes native future request before LOAD",
        allocatorBounded.ranks[0].hardwareFits == false && allocatorBounded.ranks[1].hardwareFits == true)
    for lanes in [2, 4, 6, 8] {
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
        ("foreign model", { (x: inout [String: Any]) in var r = x["request"] as! [String: Any]; r["runtimeModelID"] = "registered_ternary_bonsai_2_27b"; x["request"] = r }),
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
    let assistantPolicy = try ClusterQwenTensorAssistantPolicy(depth: 4,
        inventorySHA256: String(repeating: "a", count: 64))
    let assistant = try ClusterPlacementTensorAssistantQuote(policy: assistantPolicy,
        residentBytes: gib, loadBytes: 5 * gib, largestAllocationBytes: gib)
    for lanes in [1, 2, 4, 6, 8] {
        let base = try quote(max(2, lanes))
        let value = try ClusterPlacementTensorBatchQuote(request: request, lanes: lanes, chunkTokens: 128,
            perLaneStateBytes: 4 * gib, sharedBytesExcludingCollectives: 80 * gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                requestBytesExcludingCollectives: lanes * 4 * gib + 80 * gib,
                maximumCollectivePayloadBytes: base.allowance.maximumCollectivePayloadBytes,
                maximumCollectiveFrameBytes: base.allowance.maximumCollectiveFrameBytes,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }), assistant: assistant)
        // Every scope prices the reference request its caller plans.
        var p = ClusterPlacementPolicy(); p.leader = "a"
        p.promptTokens = request.promptTokens; p.outputTokens = request.outputTokens
        if lanes == 1 { try value.applySingleton(to: &p, layout: layout) }
        else { try ClusterPlacementBatchScope(request: request, lanes: lanes, tensorParallelQuote: value).apply(to: &p, layout: layout) }
        let planned = try ClusterPlacementPlanner.plan(devices: fast, layout: layout, policy: p, link: link)
        let candidate = try ClusterPlacementPlanner.evaluate(devices: fast, cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: layout, policy: p, link: link)
        checks.require("TP assistant \(lanes): no pipeline can silently omit the saved assistant", planned.chosen?.mode == .tensorParallel)
        checks.require("TP assistant \(lanes): complete future head and request coexist through LOAD",
            zip(candidate.ranks, noBatchReservation.ranks).allSatisfy {
                $0.loadNeedBytes == $1.loadNeedBytes + value.allowance.reservedBytes + assistant.loadBytes
                    && $0.weightsBytes == $1.weightsBytes + assistant.residentBytes
            })
        var headAllocator = try JSONSerialization.jsonObject(with: fast[0].profile.encoded()) as! [String: Any]
        headAllocator["allocatorLimitBytes"] = candidate.ranks[0].weightsBytes
            + value.allowance.reservedBytes + assistant.loadBytes - assistant.residentBytes
            + max(largest, assistant.largestAllocationBytes) + fast[0].profile.memory.allocatorHeadroomBytes - 1
        let headProfile = try ClusterDeviceProfile.decode(JSONSerialization.data(withJSONObject: headAllocator))
        let headLimited = try ClusterPlacementPlanner.evaluate(devices: [
            .init(label: "a", profile: headProfile, speed: fast[0].speed), fast[1]], cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: layout, policy: p, link: link)
        checks.require("TP assistant \(lanes): allocator also holds the future constructor and read buffers",
            headLimited.ranks[0].hardwareFits == false && headLimited.ranks[1].hardwareFits == true)
        checks.require("TP assistant \(lanes): roundtrip preserves versioned policy and full ledger",
            try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(value)) == value
                && value.schema != ClusterPlacementTensorBatchQuote.schemaName)
        try value.requireAssistant(assistantPolicy)
        checks.refuses("TP assistant \(lanes): absent saved policy cannot borrow assistant quote", because: "saved assistant policy") {
            try value.requireAssistant(nil)
        }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object["assistant"] = nil
        checks.refuses("TP assistant \(lanes): stripped assistant cannot become a legacy quote", because: "tensor batch quote") {
            _ = try ClusterPlacementTensorBatchQuote.decode(JSONSerialization.data(withJSONObject: object))
        }
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object["schema"] = ClusterPlacementTensorBatchQuote.schemaName
        checks.refuses("TP assistant \(lanes): old schema cannot ignore head residency", because: "tensor batch quote") {
            _ = try ClusterPlacementTensorBatchQuote.decode(JSONSerialization.data(withJSONObject: object))
        }
        if lanes == 1 {
            checks.refuses("TP assistant singleton: no concurrent scope fabricated", because: "priced native pipeline batch scope") {
                _ = try ClusterPlacementBatchScope(request: request, lanes: 1, tensorParallelQuote: value)
            }
        }
    }

}

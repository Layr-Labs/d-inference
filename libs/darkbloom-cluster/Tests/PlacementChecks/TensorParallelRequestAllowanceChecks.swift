import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Complete native quotes are floors, and expert reductions retain top-K.
/// Constructed metadata and actual planner only; no native/GPU execution.
func checkTensorParallelRequestAllowance(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let base = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored)
    let layout = try executing(base, [.tensorParallel])
    let partial = layout.tensorParallel!.family.partialBytesPerToken
    let chunk = layout.maximumChunkTokens, context = layout.maximumContextTokens
    var observedBounds: [Int] = []
    func quote(base: Int, topK: Int = 1) throws -> ClusterTensorParallelRequestAllowance {
        try .init(maximumContextTokens: context, maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: base, maximumCollectivePayloadBytes: topK * partial * chunk,
            maximumCollectiveFrameBytes: topK * partial * chunk + 1024) {
                observedBounds.append($0)
                return $0 + 16_384
            }
    }
    let small = try quote(base: 0)
    let expert = try quote(base: 123, topK: 4)
    checks.require("TP allowance: selected experts multiply the actual FP32 reduction payload", expert.maximumCollectivePayloadBytes == 4 * partial * chunk)
    checks.require("TP allowance: eight frame allocations are bounded independently, not rounded as one sum",
        expert.collectiveScratchBytes == 8 * (expert.maximumCollectivePayloadBytes + 1024 + 16_384)
            && expert.reservedBytes == 123 + expert.collectiveScratchBytes
            && observedBounds == [partial * chunk + 1024, 4 * partial * chunk + 1024])
    let unchanged = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
    let family = (unchanged["tensorParallel"] as! [String: Any])["family"] as! [String: Any]
    checks.require("TP allowance: default family does not encode a new field", family["requestAllowance"] == nil)

    func changed(_ allowance: ClusterTensorParallelRequestAllowance, partialBytes: Int? = nil,
                 edit: (inout [String: Any]) -> Void = { _ in }) throws -> ClusterModelLayout {
        var object = unchanged
        var tp = object["tensorParallel"] as! [String: Any]
        var f = tp["family"] as! [String: Any]
        var a = try JSONSerialization.jsonObject(with: JSONEncoder().encode(allowance)) as! [String: Any]
        edit(&a)
        f["requestAllowance"] = a
        if let partialBytes { f["partialBytesPerToken"] = partialBytes }
        tp["family"] = f; object["tensorParallel"] = tp
        return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    _ = try changed(expert, partialBytes: partial * 4)
    for (name, edit) in [
        ("undersized expert payload", { (a: inout [String: Any]) in a["maximumCollectivePayloadBytes"] = partial * chunk }),
        ("undersized encoded frame", { (a: inout [String: Any]) in a["maximumCollectiveFrameBytes"] = expert.maximumCollectivePayloadBytes - 1 }),
        ("short context", { (a: inout [String: Any]) in a["maximumContextTokens"] = context - 1 }),
        ("short chunk", { (a: inout [String: Any]) in a["maximumChunkTokens"] = chunk - 1 }),
        ("insufficient scratch", { (a: inout [String: Any]) in a["collectiveScratchBytes"] = 1 }),
        ("negative base", { (a: inout [String: Any]) in a["requestBytesExcludingCollectives"] = -1 }),
        ("overflowing total", { (a: inout [String: Any]) in a["requestBytesExcludingCollectives"] = Int.max })
    ] {
        checks.refuses("TP allowance: decoded \(name) refuses", because: "request allowance") {
            _ = try changed(expert, partialBytes: partial * 4, edit: edit)
        }
    }
    checks.refuses("TP allowance: allocator bound below payload refuses", because: "request allowance") {
        _ = try ClusterTensorParallelRequestAllowance(maximumContextTokens: context, maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: 0, maximumCollectivePayloadBytes: 100, maximumCollectiveFrameBytes: 1124) { $0 - 1 }
    }
    checks.refuses("TP allowance: constructor rejects overflowing scratch", because: "request allowance") {
        _ = try ClusterTensorParallelRequestAllowance(maximumContextTokens: context, maximumChunkTokens: chunk,
            requestBytesExcludingCollectives: 0, maximumCollectivePayloadBytes: Int.max, maximumCollectiveFrameBytes: Int.max) { $0 }
    }
    let page = 16_384, alignedPayload = 2 * 16_384
    let aligned = try ClusterTensorParallelRequestAllowance(maximumContextTokens: 1024, maximumChunkTokens: 512,
        requestBytesExcludingCollectives: 0, maximumCollectivePayloadBytes: alignedPayload,
        maximumCollectiveFrameBytes: alignedPayload + 1024) { (($0 + page - 1) / page) * page }
    checks.require("TP allowance: authentication overhead crosses an aligned allocator page on every frame",
        aligned.collectiveScratchBytes == 8 * (alignedPayload + page))
    checks.refuses("TP allowance: explicit encoded frame cannot be smaller than its payload", because: "request allowance") {
        _ = try ClusterTensorParallelRequestAllowance(maximumContextTokens: 1024, maximumChunkTokens: 512,
            requestBytesExcludingCollectives: 0, maximumCollectivePayloadBytes: 1024,
            maximumCollectiveFrameBytes: 1023) { $0 }
    }
    let devices = try [SyntheticMac.idle(64).device("a"), SyntheticMac.idle(64).device("b")]
    let link = linkCosts(reductionMicroseconds: 45)
    func evaluate(_ value: ClusterModelLayout, policy: ClusterPlacementPolicy = .init()) throws -> ClusterPlacementCandidate {
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: value, policy: policy, link: link)
    }
    let previous = try evaluate(layout), below = try evaluate(changed(small))
    checks.require("TP allowance: a smaller complete quote never reduces existing request reservations",
        zip(previous.ranks, below.ranks).allSatisfy { $0.requestNeedBytes == $1.requestNeedBytes && $0.needBytes == $1.needBytes })
    let high = try quote(base: 80 * gib), highLayout = try changed(high), raised = try evaluate(highLayout)
    checks.require("TP allowance: larger complete quote wins without adding existing KV/workspace twice",
        zip(raised.ranks, devices).allSatisfy { rank, device in
            rank.requestNeedBytes == high.reservedBytes + device.profile.memory.loadingHeadroomBytes
        })
    checks.require("TP allowance: complete native floor affects resident working-set and hardware-fit checks",
        raised.ranks.allSatisfy { !$0.withinGPUWorkingSet && $0.hardwareFits == false })
    var extended = ClusterPlacementPolicy()
    extended.promptTokens = context; extended.outputTokens = 1
    extended.largestContextTokens = context + 1; extended.requestChargeEveryRankBytes = 0
    checks.refuses("TP allowance: explicit larger request cannot reuse a shorter native quote", because: "does not cover") {
        _ = try evaluate(highLayout, policy: extended)
    }
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: highLayout, policy: extended, link: link)
    checks.require("TP allowance: automatic search does not offer TP beyond its priced envelope",
        result.chosen?.mode.usesTensorParallelDecode != true && result.alternatives.allSatisfy { !$0.mode.usesTensorParallelDecode })

    // Real retained headers exercise the production layout's quote path.
    // The old state ledger and stored fusion inputs provide independent sums.
    for (name, input) in [("9B", inputs.nine), ("27B", inputs.twentySeven)] {
        let family = try QwenDensePlacementFamily(configuration: input.configuration)
        let canonical = try family.requireRegisteredInventory(input.stored)
        let plan = family.tensorParallel!
        let context = family.largestContextTokens, chunk = family.maximumChunkTokens
        func budget(_ tensors: [QwenDenseCanonicalTensor], bound: (Int) throws -> Int = { $0 + 16_384 }) throws -> QwenTensorParallelRequestBudget {
            try .derive(geometry: family.geometry, plan: plan, tensors: tensors,
                maximumTokens: context, chunkSize: chunk, allocationBound: bound)
        }
        let native = try budget(canonical)
        let quoted = try ClusterPlacementLayouts.layout(configuration: input.configuration,
            tensors: input.stored, tensorParallelAllocationBound: { $0 + 16_384 })
        let allowance = quoted.tensorParallel!.family.requestAllowance!
        let recurrentLayers = family.geometry.layers - family.geometry.layers / family.geometry.fullAttentionInterval
        let storedFusionBytes = input.stored.reduce(0) {
            $0 + family.requestWorkBytes(ofStoredTensor: $1.name, storedBytes: $1.byteCount)
        }
        let constants = input.stored.filter {
            ($0.name.contains(".linear_attn.out_proj.") || $0.name.contains(".self_attn.o_proj.")
                || $0.name.contains(".mlp.down_proj."))
                && ($0.name.hasSuffix(".scales") || $0.name.hasSuffix(".biases"))
        }
        checks.require("Qwen \(name): retained FP32 projection constants are charged outside loaded parameters",
            !constants.isEmpty && constants.allSatisfy { $0.dtype == "BF16" }
                && native.projectionConstantBytes == constants.reduce(0) { $0 + 2 * $1.byteCount + 16_384 })
        checks.require("Qwen \(name): complete TP quote retains the independent whole-model state ledger",
            native.stateBytes == QwenPlacementCharge.wholeModelStateBytes(geometry: family.geometry,
                contextTokens: context, chunk: chunk))
        checks.require("Qwen \(name): every canonical fusion bank is charged with its own allocation bound",
            native.fusionBytes == storedFusionBytes + 3 * recurrentLayers * 16_384)
        checks.require("Qwen \(name): production layout covers full context, sealed reductions and logits",
            allowance.maximumContextTokens == context && allowance.maximumChunkTokens == chunk
                && allowance.maximumCollectivePayloadBytes == chunk * plan.hiddenSize * 4
                && allowance.maximumCollectiveFrameBytes == chunk * plan.hiddenSize * 4 + QwenTensorParallelSealCodec.frameOverhead
                && allowance.reservedBytes == native.stateBytes + native.fusionBytes + native.transientBytes
                    + 3 * (plan.vocabularySize * 4 + 16_384) + native.projectionConstantBytes + allowance.collectiveScratchBytes)
        let candidate = try evaluate(executing(quoted, [.tensorParallel]))
        checks.require("Qwen \(name): each planner rank reserves at least the native TP request plus headroom",
            zip(candidate.ranks, devices).allSatisfy {
                $0.requestNeedBytes >= allowance.reservedBytes + $1.profile.memory.loadingHeadroomBytes
            })
        checks.refuses("Qwen \(name): incomplete canonical fusion inventory refuses", because: "fusion input") {
            _ = try budget(canonical.filter { !$0.name.contains("linear_attn.in_proj_qkv.weight") })
        }
        checks.refuses("Qwen \(name): duplicated canonical inventory refuses", because: "canonical inventory") {
            _ = try budget(canonical + [canonical[0]])
        }
        checks.refuses("Qwen \(name): missing persistent projection constant refuses", because: "projection constant") {
            _ = try budget(canonical.filter { $0.name != constants[0].name })
        }
        checks.refuses("Qwen \(name): underestimated allocator bound refuses", because: "allocator bound") {
            _ = try budget(canonical, bound: { $0 - 1 })
        }
    }
}

/// Header-only fixture of the exact registered Qwen 3.6 artifact. Registration
/// verifies its full text inventory before the memory regression is evaluated.
func checkQwenMoEProjectionAllowance(golden: URL, _ checks: PlacementChecks) throws {
    let fixture = golden.deletingLastPathComponent().appendingPathComponent("Inputs/qwen36-projection-budget.json")
    let input = try JSONDecoder().decode(RetainedQwenInputs.Profile.self, from: Data(contentsOf: fixture))
    let family = try QwenDensePlacementFamily(configuration: input.configuration)
    let canonical = try family.requireRegisteredInventory(input.stored)
    let plan = family.tensorParallel!
    let budget = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry, plan: plan,
        tensors: canonical, maximumTokens: family.largestContextTokens,
        chunkSize: family.maximumChunkTokens, allocationBound: { $0 + 16_384 })
    let mib = 1_048_576
    // Exact whole-bank FP32 casts: expert down 1,280 MiB, shared down 5 MiB,
    // mixer outputs 40 MiB. Each of 120 projections has two retained arrays.
    checks.require("Qwen 3.6: complete quote includes full persistent expert, shared and mixer constants",
        budget.projectionConstantBytes == 1325 * mib + 240 * 16_384)
    checks.require("Qwen 3.6: collective retains all eight expert vectors until router weighting",
        plan.expertsPerToken == 8 && plan.maximumPartialBytesPerToken == 8 * 2048 * 4
            && budget.allowance.maximumCollectivePayloadBytes == family.maximumChunkTokens * 8 * 2048 * 4
            && plan.reductionsPerForward == 120)
    let layout = try ClusterPlacementLayouts.layout(configuration: input.configuration,
        tensors: input.stored, tensorParallelAllocationBound: { $0 + 16_384 })
    checks.require("Qwen 3.6: planner and native budget retain the same widened-constant charge",
        layout.tensorParallel!.family.requestAllowance!.reservedBytes == budget.allowance.reservedBytes
            && budget.allowance.requestBytesExcludingCollectives == budget.stateBytes + budget.fusionBytes
                + budget.transientBytes + budget.logitsBytes + budget.projectionConstantBytes)
    let constants = canonical.filter { $0.name.contains(".switch_mlp.down_proj.") && $0.name.hasSuffix(".scales") }
    checks.require("Qwen 3.6: regression fixture covers every real expert layer", constants.count == 40)
    checks.refuses("Qwen 3.6: missing expert constant cannot become a smaller quote", because: "projection constant") {
        _ = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry, plan: plan,
            tensors: canonical.filter { $0.name != constants[0].name }, maximumTokens: family.largestContextTokens,
            chunkSize: family.maximumChunkTokens, allocationBound: { $0 + 16_384 })
    }
}

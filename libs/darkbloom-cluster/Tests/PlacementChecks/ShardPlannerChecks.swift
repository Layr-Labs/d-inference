import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Sharded deployments only (owner, 2026-10-13): the planner's automatic
/// candidates are tensor parallel (shares by heads and channels, unequal where
/// the family's plan allows it), pipeline (a cut from the hardware, compact
/// decode as its variant) and, for three or more members, tensor parallel
/// stages in a pipeline (predicted only: no runtime executes it yet). Phase
/// split, phase split + MTP, the pipeline-prefill/tensor-decode hybrid and the
/// per-request "alone" route are kept but off unless the policy opts in
/// (`handOffModes`, `aloneRoute`). Constructed Macs (the older-Mac rates are
/// floor-plus-bandwidth test inputs, not claims about those machines) and the
/// recorded M3 Ultra + M5 Ultra profiles. No model, no GPU, no network: not a
/// hardware pass.
func checkShardPlanner(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    try checkHandOffOffByDefault(big, golden: golden, checks)
    try checkShardChoiceBySyntheticPairs(big, checks)
    try checkShardChoiceOnRecordedPair(big, golden: golden, checks)
    try checkTensorPipelineThreeMembers(big, checks)
    try checkUnequalTensorShares(big, checks)
    try checkShardRules(big, checks)
    try checkAloneRouteOffByDefault(big, golden: golden, checks)
}

private func shardPolicy(prompt: Int = 1024, outputs: Int = 128, handOff: Bool = false) -> ClusterPlacementPolicy {
    var p = ClusterPlacementPolicy()
    p.promptTokens = prompt; p.outputTokens = outputs; p.handOffModes = handOff
    return p
}

private func option(_ result: ClusterPlacementResult, _ kind: ClusterShardOption.Kind) -> ClusterShardOption? {
    result.shards?.options.first { $0.kind == kind }
}

private func recordedPair(_ golden: URL) throws -> (ClusterDeviceProfile, ClusterDeviceProfile) {
    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    return (try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-a.json"))),
            try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-b.json"))))
}

// MARK: - Hand-off modes: kept, off by default

private func checkHandOffOffByDefault(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    checks.require("shards: phase split, phase split + MTP and the pipeline-prefill/tensor-decode hybrid are the hand-off modes; pipeline, compact decode, tensor parallel and the pipeline's speculative rounds are sharded",
        ClusterGenerationMode.allCases.filter(\.isHandOff) == [.phaseSplit, .phaseSplitMTP, .pipelinePrefillTensorDecode]
            && ClusterGenerationMode.allCases.filter(\.isSharded) == [.pipeline, .pipelineCompactDecode, .tensorParallel, .pipelineMTP])
    checks.require("shards: the policy's hand-off opt-in is off by default", ClusterPlacementPolicy().handOffModes == false)
    let (a, b) = try recordedPair(golden)
    // The M3 Ultra + M5 Ultra with whole-model 27B rates in the measured range:
    // the earlier planner chose a phase split + MTP here (one Mac decoding alone).
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: measured(prefill: 300, decode: 35.7)),
                   ClusterPlacementDevice(label: "mac-b", profile: b, speed: measured(prefill: 1530, decode: 58))]
    let sharded = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: shardPolicy())
    checks.require("shards M3 Ultra + M5 Ultra 27B, default: a sharded mode is chosen (no phase split), both Macs hold layers, and no alternative is a hand-off mode",
        sharded.chosen.map { $0.mode.isSharded && $0.ranks.count == 2 && $0.ranks.allSatisfy { $0.endLayer > $0.firstLayer } } == true
            && sharded.alternatives.allSatisfy { !$0.mode.isHandOff })
    let optedIn = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: shardPolicy(handOff: true))
    checks.require("shards M3 Ultra + M5 Ultra 27B, hand-off opt-in: the phase split code is still there and chosen as before",
        optedIn.chosen?.mode.isPhaseSplit == true)
    checks.require("shards: a plan under the hand-off opt-in is the earlier planner's (no shard table); the default carries one",
        optedIn.shards == nil && sharded.shards != nil && sharded.shards?.handOffModes == false)
    // Explicitly listing a hand-off mode is not an opt-in: the policy flag is the one switch.
    var listed = shardPolicy(); listed.modes = [.phaseSplit, .phaseSplitMTP, .pipeline]
    let listedResult = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: listed)
    checks.require("shards: a mode list naming phase split does not opt in; only handOffModes does",
        listedResult.chosen?.mode == .pipeline)
    var onlyHandOff = shardPolicy(); onlyHandOff.modes = [.phaseSplitMTP]
    checks.refuses("shards: a policy that allows only hand-off modes, without the opt-in, is refused in words",
                   because: "hand-off modes are off") {
        _ = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: onlyHandOff)
    }
    // The table says the hand-off modes are off, in its own words.
    let lines = ClusterPlacementExplanation.describe(sharded, devices: devices, layout: big)
    checks.require("shards: the plan's words carry the sharded candidates with each one's prediction and reason, and say the hand-off modes are off by default",
        lines.contains("Sharded deployment candidates")
            && lines.contains { $0.contains("pipeline:") && $0.contains("chosen") }
            && lines.contains { $0.contains("tensor parallel:") }
            && lines.contains { $0.contains("off by default") && $0.contains("phase split") })
}

// MARK: - Synthetic pairs: when tensor parallel, when pipeline

private func checkShardChoiceBySyntheticPairs(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big, [.tensorParallel, .pipelinePrefillTensorDecode])
    struct Mac { let gib: Double; let chip: String; let floor: Double; let bw: Double; let prefill: Double }
    let m1max = Mac(gib: 64, chip: "Apple M1 Max", floor: 25, bw: 400, prefill: 120)
    let m2max = Mac(gib: 96, chip: "Apple M2 Max", floor: 22, bw: 400, prefill: 150)
    let m2ultra = Mac(gib: 192, chip: "Apple M2 Ultra", floor: 20, bw: 800, prefill: 260)
    func devices(_ a: Mac, _ b: Mac) throws -> [ClusterPlacementDevice] {
        [try SyntheticMac.idle(a.gib).device("a", speed: modelled(floorMs: a.floor, bandwidthGBs: a.bw, weightBytes: weights, prefill: a.prefill), chip: a.chip),
         try SyntheticMac.idle(b.gib).device("b", speed: modelled(floorMs: b.floor, bandwidthGBs: b.bw, weightBytes: weights, prefill: b.prefill), chip: b.chip)]
    }
    for (name, a, b) in [("2x M1 Max 64 GB", m1max, m1max), ("2x M2 Ultra 192 GB", m2ultra, m2ultra), ("M1 Max 64 GB + M2 Max 96 GB", m1max, m2max)] {
        let pair = try devices(a, b)
        let fast = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: shardPolicy(), link: linkCosts(reductionMicroseconds: 45))
        let tp = option(fast, .tensorParallel), pp = option(fast, .pipeline)
        checks.require("shards \(name), keyed reduction 45 us (bandwidth-bound decode): tensor parallel is chosen, the pipeline is listed as slower with its predicted time",
            fast.chosen?.mode == .tensorParallel && fast.shards?.chosen == .tensorParallel && tp?.verdict == .chosen
                && pp?.verdict == .slower && (pp?.prediction?.requestSeconds ?? 0) > (tp?.prediction?.requestSeconds ?? .infinity))
        checks.require("shards \(name): the tensor-parallel option names its shares (equal for equal Macs) and each member holds about its share of the weights",
            tp.map { o in
                // Equal Macs keep equal shares; unequal Macs may take one of
                // the plan's kernel-aligned weighted options. Either way the
                // shares sum to one and each member holds about its share.
                let shares = o.shares ?? []
                return shares.count == 2 && abs(shares.reduce(0, +) - 1) < 1e-9 && o.members.count == 2
                    && (a.chip != b.chip || shares == [0.5, 0.5])
                    && zip(o.members, shares).allSatisfy { m, s in
                        Double(m.weightsBytes) < Double(weights) * (s + 0.1) && Double(m.weightsBytes) > Double(weights) * (s - 0.1) }
            } == true)
        checks.require("shards \(name): the hybrid (pipeline prefill, tensor decode) is never chosen by default",
            fast.chosen?.mode != .pipelinePrefillTensorDecode && fast.alternatives.allSatisfy { !$0.mode.isHandOff })
        let slow = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: shardPolicy(), link: linkCosts(reductionMicroseconds: 350))
        checks.require("shards \(name), keyed reduction 350 us: the pipeline is chosen and tensor parallel is listed as slower",
            slow.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true
                && option(slow, .tensorParallel)?.verdict == .slower)
        checks.require("shards \(name): two members, so tensor parallel x pipeline needs a third",
            option(fast, .tensorPipeline)?.verdict == .needsMoreMembers)
    }
}

// MARK: - The recorded M3 Ultra + M5 Ultra

private func checkShardChoiceOnRecordedPair(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let (a, b) = try recordedPair(golden)
    // A shard probe like the M5 Max's (a half stepping in 84.5 % of the whole):
    // the per-token floor dominates, so a half saves little and the slower Mac's share sets the pace.
    func probed(_ prefill: Double, _ decode: Double) -> ClusterDeviceSpeed {
        .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode,
            tensorShardPrefillTokensPerSecond: prefill * 1.66, tensorShardDecodeTokensPerSecond: decode / 0.845),
            sustained: nil, explanation: "constructed")
    }
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: probed(300, 35.7)),
                   ClusterPlacementDevice(label: "mac-b", profile: b, speed: probed(1530, 58))]
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: try executing(big, [.tensorParallel]), policy: shardPolicy(),
        link: linkCosts(reductionMicroseconds: 45))
    checks.require("shards M3 Ultra + M5 Ultra (floor-bound decode, unequal Macs): the pipeline is chosen; tensor parallel is predicted slower and said so",
        result.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true
            && option(result, .tensorParallel)?.verdict == .slower && option(result, .tensorParallel)?.prediction != nil)
    // The adapter advertises TP, but a new pair has no keyed reduction measurement yet.
    let today = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: shardPolicy())
    checks.require("shards M3 Ultra + M5 Ultra, TP-capable runtime, no reduction measured: pipeline chosen; tensor parallel says the reduction is not measured",
        today.chosen?.mode == .pipeline && option(today, .tensorParallel)?.verdict == .reductionNotMeasured)
    if let chosen = option(today, .pipeline) {
        checks.require("shards M3 Ultra + M5 Ultra: the pipeline option names its cut, each member's layers and bytes, and its predicted speed",
            chosen.cuts.count == 1 && chosen.members.count == 2 && chosen.members.allSatisfy { $0.weightsBytes > 0 && $0.endLayer > $0.firstLayer }
                && (chosen.prediction?.decodeTokensPerSecond ?? 0) > 0)
    } else {
        checks.require("shards M3 Ultra + M5 Ultra: a pipeline option is listed", false)
    }
}

// MARK: - Three members: tensor parallel stages in a pipeline (predicted only)

private func checkTensorPipelineThreeMembers(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big, [.tensorParallel])
    let ultra = modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260)
    let maxSpeed = modelled(floorMs: 25, bandwidthGBs: 400, weightBytes: weights, prefill: 120)
    let three = [try SyntheticMac.idle(192).device("u1", speed: ultra, chip: "Apple M2 Ultra"),
                 try SyntheticMac.idle(192).device("u2", speed: ultra, chip: "Apple M2 Ultra"),
                 try SyntheticMac.idle(64).device("m1", speed: maxSpeed, chip: "Apple M1 Max")]
    let result = try ClusterPlacementPlanner.plan(devices: three, layout: layout, policy: shardPolicy(), link: linkCosts(reductionMicroseconds: 45))
    let tpp = option(result, .tensorPipeline)
    checks.require("shards 3 members: tensor parallel x pipeline is predicted (a tensor-parallel stage and a pipeline cut), with every member's bytes, and never chosen (no runtime executes it yet)",
        tpp?.verdict == .notExecutedByRuntime && (tpp?.stages?.count ?? 0) >= 2 && (tpp?.stages?.contains { $0.count >= 2 } ?? false)
            && tpp?.members.count == 3 && tpp?.prediction != nil && tpp?.cuts.count == (tpp?.stages?.count ?? 0) - 1
            && result.chosen.map { $0.ranks.count == 2 } == true)
    checks.require("shards 3 members: every member of the tensor-parallel x pipeline option holds bytes and the shares cover the model",
        tpp.map { o in o.members.allSatisfy { $0.weightsBytes > 0 } && o.members.reduce(0) { $0 + $1.weightsBytes } >= weights } == true)
    // Without the family's tensor-parallel facts no tensor-parallel stage can be planned.
    let plain = try syntheticLayout(layers: 16, layerGiB: 1)
    let noTP = try ClusterPlacementPlanner.plan(devices: three, layout: plain, policy: shardPolicy(), link: linkCosts(reductionMicroseconds: 45))
    checks.require("shards 3 members, a model whose adapter has no tensor-parallel plan: tensor parallel and tensor parallel x pipeline say so; a pipeline is chosen",
        option(noTP, .tensorParallel)?.verdict == .adapterHasNoTensorParallel
            && option(noTP, .tensorPipeline)?.verdict == .adapterHasNoTensorParallel
            && noTP.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true)
}

// MARK: - Unequal shares for unequal Macs, where the family's plan allows them

private func checkUnequalTensorShares(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    guard let tp = big.tensorParallel else { checks.require("shards: the 27B carries tensor-parallel facts", false); return }
    checks.require("shards: the dense Qwen plan hands out no free share units (its unequal shares are its kernel-aligned options)",
        tp.family.shareUnits == nil && !(tp.family.shareOptions ?? []).isEmpty)
    // Equal-only facts of the same model, the reference for "unequal is faster".
    let equalFamily = ClusterTensorParallelFamilyPlan(plan: tp.family.plan, ranks: tp.family.ranks, reductionsPerLayer: tp.family.reductionsPerLayer,
        reductionsPerStep: tp.family.reductionsPerStep, partialBytesPerToken: tp.family.partialBytesPerToken,
        stateDividesByHeads: tp.family.stateDividesByHeads)
    let equalFacts = ClusterTensorParallelLayout(family: equalFamily, layerDividedBytes: tp.layerDividedBytes, layerReplicatedBytes: tp.layerReplicatedBytes,
        ingressDividedBytes: tp.ingressDividedBytes, ingressReplicatedBytes: tp.ingressReplicatedBytes,
        egressDividedBytes: tp.egressDividedBytes, egressReplicatedBytes: tp.egressReplicatedBytes)
    // The same facts from a family whose plan can cut at any of 8 head groups.
    let family = ClusterTensorParallelFamilyPlan(plan: tp.family.plan, ranks: tp.family.ranks, reductionsPerLayer: tp.family.reductionsPerLayer,
        reductionsPerStep: tp.family.reductionsPerStep, partialBytesPerToken: tp.family.partialBytesPerToken,
        stateDividesByHeads: tp.family.stateDividesByHeads, shareUnits: 8)
    let unequalFacts = ClusterTensorParallelLayout(family: family, layerDividedBytes: tp.layerDividedBytes, layerReplicatedBytes: tp.layerReplicatedBytes,
        ingressDividedBytes: tp.ingressDividedBytes, ingressReplicatedBytes: tp.ingressReplicatedBytes,
        egressDividedBytes: tp.egressDividedBytes, egressReplicatedBytes: tp.egressReplicatedBytes)
    let layout = try executing(try big.with(tensorParallel: unequalFacts), [.tensorParallel])
    let equal = try executing(try big.with(tensorParallel: equalFacts), [.tensorParallel])
    let devices = [try SyntheticMac.idle(64).device("max", speed: modelled(floorMs: 25, bandwidthGBs: 400, weightBytes: weights, prefill: 120), chip: "Apple M1 Max"),
                   try SyntheticMac.idle(192).device("ultra", speed: modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260), chip: "Apple M2 Ultra")]
    let link = linkCosts(reductionMicroseconds: 45)
    let uneven = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: shardPolicy(), link: link)
    let even = try ClusterPlacementPlanner.plan(devices: devices, layout: equal, policy: shardPolicy(), link: link)
    let unevenTP = option(uneven, .tensorParallel), evenTP = option(even, .tensorParallel)
    let shares = unevenTP?.shares ?? []
    let ultraShare = zip(unevenTP?.members ?? [], shares).first { $0.0.device == "ultra" }?.1 ?? 0
    checks.require("shards M1 Max + M2 Ultra, a plan with 8 head groups: the faster Mac takes the larger share (in whole groups) and the shares sum to one",
        shares.count == 2 && abs(shares.reduce(0, +) - 1) < 1e-9 && ultraShare > 0.5 && shares.allSatisfy { ($0 * 8).rounded() == $0 * 8 })
    checks.require("shards M1 Max + M2 Ultra: unequal shares are predicted faster than equal ones, and the faster Mac holds more bytes",
        (unevenTP?.prediction?.decodeTokensPerSecond ?? 0) > (evenTP?.prediction?.decodeTokensPerSecond ?? .infinity)
            && (unevenTP?.members.first { $0.device == "ultra" }?.weightsBytes ?? 0) > (unevenTP?.members.first { $0.device == "max" }?.weightsBytes ?? .max))
}

// MARK: - Records, adapters, runtimes

private func checkShardRules(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big, [.tensorParallel])
    let speed = modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260)
    let devices = [try SyntheticMac.idle(192).device("a", speed: speed, chip: "Apple M2 Ultra"),
                   try SyntheticMac.idle(192).device("b", speed: speed, chip: "Apple M2 Ultra")]
    var gated = shardPolicy()
    gated.admitsShape = { _, _, mode in mode != .tensorParallel }
    let refused = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: gated, link: linkCosts(reductionMicroseconds: 45))
    checks.require("shards: a mode that failed a qualification check at this shape is never planned there (tensor parallel refused by the records: pipeline chosen, verdict failedQualification)",
        refused.chosen.map { $0.mode != .tensorParallel } == true && option(refused, .tensorParallel)?.verdict == .failedQualification)
    var pipelineGated = shardPolicy()
    pipelineGated.admitsShape = { _, cuts, mode in mode != .pipeline || cuts == [32] }
    let atCut = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: pipelineGated)
    checks.require("shards: records that admit the pipeline only at cut 32 plan it only there",
        atCut.chosen.map { $0.mode != .pipeline || $0.cuts == [32] } == true)
    let today = try ClusterPlacementPlanner.plan(devices: devices, layout: try notExecuting(big), policy: shardPolicy(), link: linkCosts(reductionMicroseconds: 45))
    checks.require("shards: predicted faster but not executed by a runtime that lists no tensor-parallel mode: tensor parallel says so and the pipeline serves",
        option(today, .tensorParallel)?.verdict == .notExecutedByRuntime && today.chosen?.mode != .tensorParallel)
    let mimo = try surveyedMiMoLayout()
    // Two 192 GB Macs: two 128 GB Macs admit 156 GiB at rest together, less than the 173 GB model needs.
    let mimoDevices = [try SyntheticMac.idle(192).device("a", chip: "Apple M2 Ultra"), try SyntheticMac.idle(192).device("b", chip: "Apple M2 Ultra")]
    let mimoPlan = try ClusterPlacementPlanner.plan(devices: mimoDevices, layout: mimo, policy: shardPolicy())
    checks.require("shards: a model whose adapter lacks tensor parallel (the surveyed MiMo) gets the pipeline and says why",
        mimoPlan.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true
            && option(mimoPlan, .tensorParallel)?.verdict == .adapterHasNoTensorParallel)
}

// MARK: - The router's alone route: kept, off by default

private func checkAloneRouteOffByDefault(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let (a, b) = try recordedPair(golden)
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: measured(prefill: 300, decode: 35.7)),
                   ClusterPlacementDevice(label: "mac-b", profile: b, speed: measured(prefill: 1530, decode: 58))]
    let off = ClusterRequestRouter.Setup(devices: devices, cuts: [8], mode: .phaseSplitMTP, schedule: .oneChunkLookahead, layout: big)
    let offRoute = try ClusterRequestRouter.decide(off, promptTokens: 64, outputTokens: 128)
    checks.require("shards router: the alone route is off by default, so even a saved phase split setup routes every request to the cluster",
        off.aloneRoute == false && off.membersHoldingWholeModel.isEmpty && offRoute.path == .pair && offRoute.reason.contains("off by default"))
    let on = ClusterRequestRouter.Setup(devices: devices, cuts: [8], mode: .phaseSplitMTP, schedule: .oneChunkLookahead, layout: big, aloneRoute: true)
    let onRoute = try ClusterRequestRouter.decide(on, promptTokens: 64, outputTokens: 128)
    checks.require("shards router: with the opt-in the alone route is kept as it was (a short prompt goes to the decoding Mac alone)",
        on.membersHoldingWholeModel.map(\.label) == ["mac-b"] && onRoute.path == .alone)
}

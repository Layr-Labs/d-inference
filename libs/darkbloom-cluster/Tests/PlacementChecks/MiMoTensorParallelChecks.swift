import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// MiMo V2.6 Flash's tensor-parallel facts and the fastest-plan rule
/// (`ClusterTensorParallelChoice.fastest`, owner policy 2026-11-01): the
/// layout built from the registered row's own metadata (configuration and
/// 1,732-tensor inventory) carries the plan, its exact per-rank bytes and the
/// routing prior; under the provider's tensor-parallel-first policy a MiMo
/// pair is placed in tensor parallel only where the planner predicts it faster
/// than the pipeline. Constructed Macs, registered metadata and constructed
/// links: no model, no GPU, no network.
func checkMiMoTensorParallel(golden: URL, _ checks: PlacementChecks) throws {
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json"))
    let tensors = try JSONDecoder().decode([Tensor].self,
        from: Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.tensor-inventory.json"))).map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        }
    let layout = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors)
    try checkMiMoLayout(layout, configuration: configuration, tensors: tensors, golden: golden, checks)
    let priced = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors,
        tensorParallelAllocationBound: { $0 + 16_384 })
    try checkMiMoRequestAllowance(priced, configuration: configuration, checks)
    let rounds = try mimoWithRounds(priced, configuration: configuration, allocationBound: { $0 + 16_384 })
    try checkMiMoRounds(priced, rounds: rounds, checks)
    try checkMiMoFastestPlan(rounds, checks)
}

/// One request's speculative charge at the registered geometry, at exact sizes: the drafter's bounded state at
/// depth 2 and 512-token chunks (438,426,984 bytes) and the window's rows (36,347,904), both pinned by
/// `MiMoTensorParallelSpeculativeTests`. The product prices it at the allocator's bound, a few pages more
/// (`placementQuotesWhatTheLoadGateChargesWithRounds`); its drafter half needs the SDK these checks do not compile.
let mimoSpeculativeRequestBytes = 438_426_984 + 36_347_904

/// The layout as the product prices it (`MiMoTensorParallelResidentRuntime.placementRounds`): MiMo tensor
/// parallel decodes in speculative rounds by default (`ClusterMiMoTensorParallel`), so its plan holds the three
/// heads whole on every rank and its reserve carries each request's speculative charge, with no speed-up credited.
func mimoWithRounds(_ layout: ClusterModelLayout, configuration: Data,
                            allocationBound: @escaping (Int) throws -> Int) throws -> ClusterModelLayout {
    guard let tp = layout.tensorParallel else { throw ProbeError("the MiMo layout carries no tensor-parallel plan") }
    let budget = try MiMoTensorParallelRequestBudget.derive(plan: MiMoTensorParallelPlan(configuration: configuration),
        slidingWindow: 128, contextTokens: 65_536, chunkTokens: 512, allocationBound: allocationBound)
    let f = tp.family
    let family = ClusterTensorParallelFamilyPlan(plan: f.plan, ranks: f.ranks, reductionsPerLayer: f.reductionsPerLayer,
        reductionsPerStep: f.reductionsPerStep, partialBytesPerToken: f.partialBytesPerToken,
        layerPartialBytesPerToken: f.layerPartialBytesPerToken, stateDividesByHeads: f.stateDividesByHeads,
        shareOptions: f.shareOptions, shareUnits: f.shareUnits,
        requestAllowance: try budget.allowance(speculativeRequestBytes: mimoSpeculativeRequestBytes, allocationBound: allocationBound),
        additionalResidentBytes: f.additionalResidentBytes,
        speculativeHead: .init(depth: ClusterMiMoTensorParallel.speculativeDepth, requestBytes: mimoSpeculativeRequestBytes,
                               decodeSpeedup: 1),
        choice: f.choice)
    return try layout.with(tensorParallel: .init(family: family, terms: tp.terms, layerDividedBytes: tp.layerDividedBytes,
        layerReplicatedBytes: tp.layerReplicatedBytes, ingressDividedBytes: tp.ingressDividedBytes,
        ingressReplicatedBytes: tp.ingressReplicatedBytes, egressDividedBytes: tp.egressDividedBytes,
        egressReplicatedBytes: tp.egressReplicatedBytes))
}

/// Rounds in the quote (2026-11-01, on by default): every rank holds the three heads whole beside its share, in
/// whole pages, and each request's speculative charge beside its reserve, so the plan admits only pairs the rank's
/// LOAD gate (shard + heads + reserve + charge, then the loading headroom) admits. Decode is credited nothing until
/// records measure the rounds. Two 128 GB M5 Max, which cannot hold MiMo alone, still fit now.
private func checkMiMoRounds(_ priced: ClusterModelLayout, rounds: ClusterModelLayout, _ checks: PlacementChecks) throws {
    guard let head = rounds.speculativeHead, let plan = rounds.tensorParallel?.family.speculativeHead,
          let allowance = rounds.tensorParallel?.family.requestAllowance,
          let plain = priced.tensorParallel?.family.requestAllowance else {
        checks.require("mimo rounds: the layout carries the three heads and the plan prices them", false)
        return
    }
    checks.require("mimo rounds: the heads are the artifact's three next-N layers (42 tensors, 1,975,640,448 bytes), in no range; depth 2, no speed-up credited",
        head.tensorCount == 42 && head.storedBytes == 1_975_640_448 && head.loadedBytes == 1_975_640_448
            && plan.depth == 2 && plan.decodeSpeedup == 1 && plan.requestBytes == mimoSpeculativeRequestBytes)
    checks.require("mimo rounds: the quoted reserve carries each request's speculative charge beside the plain reserve (+\(mimoSpeculativeRequestBytes) bytes), its collectives unchanged",
        allowance.reservedBytes == plain.reservedBytes + mimoSpeculativeRequestBytes
            && allowance.collectiveScratchBytes == plain.collectiveScratchBytes
            && allowance.maximumContextTokens == 65_536 && allowance.maximumChunkTokens == 512)
    func mac(_ label: String, _ gib: Double) throws -> ClusterPlacementDevice {
        .init(label: label, profile: try SyntheticMac.idle(gib).profile(chip: "Apple M5 Max"), speed: measured(prefill: 400, decode: 40))
    }
    let maxes = try [mac("a", 128), mac("b", 128)]
    // The pair's own probe (two M5 Ultra, keyed JACCL, 2026-10-31): sealed all-sum 29 us at 16 KB, 3,919 us at 32 MiB.
    let link = ClusterLinkCosts(probe: ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
        pointToPointSmallMicroseconds: 180, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 2_502,
        allSumSmallBytes: 16_384, allSumSmallMicroseconds: 29, allSumLargeBytes: 32 << 20, allSumLargeMicroseconds: 3_919),
        measuredUTC: "2026-10-31T00:00:00Z")!
    func tensor(_ layout: ClusterModelLayout, _ devices: [ClusterPlacementDevice]) throws -> ClusterPlacementCandidate {
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
            layout: layout, policy: ClusterPlacementPolicy(), link: link)
    }
    let before = try tensor(priced, maxes), after = try tensor(rounds, maxes)
    let pages = head.loadedBytes + head.tensorCount * SyntheticMac.page
    checks.require("mimo rounds: each rank holds the heads whole beside its share, each tensor in whole pages (+\(pages) bytes)",
        before.ranks.count == 2 && zip(before.ranks, after.ranks).allSatisfy { $1.weightsBytes == $0.weightsBytes + pages })
    checks.require("mimo rounds: each rank's request need carries the speculative charge",
        zip(before.ranks, after.ranks).allSatisfy { $1.requestNeedBytes == $0.requestNeedBytes + mimoSpeculativeRequestBytes })
    checks.require("mimo rounds: so each rank needs both more before it loads",
        zip(before.ranks, after.ranks).allSatisfy { $1.needBytes == $0.needBytes + pages + mimoSpeculativeRequestBytes })
    // The rank's LOAD gate with rounds: its exact shard, the heads, the reserve with the charge, then the headroom.
    let loadGate = 84_013_770_176 + 1_975_640_448 + allowance.reservedBytes + maxes[0].profile.memory.loadingHeadroomBytes
    checks.require("mimo rounds: the plan's need is the rank's LOAD gate (\(loadGate) bytes on a 128 GB Mac) plus its tensors' page padding",
        after.ranks.allSatisfy { $0.needBytes == loadGate + ($0.weightsBytes - 84_013_770_176 - 1_975_640_448) })
    checks.require("mimo rounds: decode and the first token are predicted as before (no credit for unmeasured rounds)",
        after.rested.decodeTokensPerSecond == before.rested.decodeTokensPerSecond
            && after.rested.firstTokenSeconds == before.rested.firstTokenSeconds)
    checks.require(String(format: "mimo rounds: two 128 GB M5 Max still fit now with the heads (each rank needs %.1f GiB of 128)",
            Double(after.ranks[0].needBytes) / Double(gib)),
        after.ranks.allSatisfy { $0.fit == .now })
    checks.require("mimo rounds: a pipeline holds no tensor-parallel heads and keeps its prediction",
        try ClusterPlacementPlanner.evaluate(devices: maxes, cuts: [41], mode: .pipeline, prefillSchedule: .serial, layout: rounds,
            policy: ClusterPlacementPolicy(), link: link) == ClusterPlacementPlanner.evaluate(devices: maxes, cuts: [41],
                mode: .pipeline, prefillSchedule: .serial, layout: priced, policy: ClusterPlacementPolicy(), link: link))
    checks.require("mimo rounds: the layout's description says the rounds, their charge and that decode is credited nothing until measured",
        ClusterPlacementExplanation.layout(rounds).contains {
            $0.contains("speculative rounds of up to 2 proposals") && $0.hasSuffix("credited nothing over one token per step until the rounds are measured.")
        } && !ClusterPlacementExplanation.layout(priced).contains { $0.contains("speculative rounds of up to") })
}

/// What one rank holds of a layout's tensor-parallel facts: every part's
/// replicated bytes and half its divided bytes.
private func mimoRankBytes(_ layout: ClusterModelLayout) -> Int {
    guard let tp = layout.tensorParallel else { return 0 }
    let parts = Array(zip(tp.layerDividedBytes, tp.layerReplicatedBytes))
        + [(tp.ingressDividedBytes, tp.ingressReplicatedBytes), (tp.egressDividedBytes, tp.egressReplicatedBytes)]
    return parts.reduce(0) { $0 + $1.1 + ($1.0 + 1) / 2 }
}

private func checkMiMoLayout(_ layout: ClusterModelLayout, configuration: Data, tensors: [ClusterPlacementStoredTensor],
                             golden: URL, _ checks: PlacementChecks) throws {
    let family = layout.tensorParallel?.family
    checks.require("mimo tp: the registered row lists tensor_parallel_v1, planned as mimo_v26_heads_and_expert_channels_v1 on two ranks, chosen only where faster",
        layout.runtimeModelID == "registered_mimo_v26_flash_mopd" && layout.generationModes.contains(.tensorParallel)
            && family?.plan == "mimo_v26_heads_and_expert_channels_v1" && family?.ranks == [2] && family?.choice == .fastest)
    checks.require("mimo tp: two sums a layer and one a step (97 a decode step), one FP32 hidden row of 16,384 bytes a token each; own KV heads; no padding",
        family?.reductionsPerLayer == 2 && family?.reductionsPerStep == 1 && family?.partialBytesPerToken == 16_384
            && family?.layerPartialBytesPerToken == nil && family?.stateDividesByHeads == true
            && family?.requestAllowance == nil && family?.speculativeHead == nil
            && layout.tensorParallel?.reductionsPerStep(layerCount: layout.layerCount) == 97)
    // The plan's own cut (`MiMoTensorParallelTests`, the verified load's shard bytes): 84,013,770,176 bytes a rank.
    let plan = try MiMoTensorParallelPlan(configuration: configuration)
    let planned = try tensors.reduce(0) { total, tensor in
        switch try plan.disposition(of: tensor.name) {
        case .excluded: return total
        case .replicated: return total + tensor.byteCount
        case .divided: return total + tensor.byteCount / plan.size
        }
    }
    checks.require("mimo tp: a rank's share is exactly the plan's cut, 84,013,770,176 bytes (the embedding whole, half the head's vocabulary rows)",
        mimoRankBytes(layout) == 84_013_770_176 && planned == 84_013_770_176)
    let routed = layout.routedExperts
    checks.require("mimo tp: 8 of 256 experts over 160,859,947,008 bytes, every byte divided; a decode step reads 10,767,036,288 bytes, \(ClusterHardwarePrior.dividedDecodeFraction(layout)) of it divided",
        routed?.routing == ClusterExpertRouting(selected: 8, experts: 256) && routed?.loadedBytes == 160_859_947_008
            && routed?.tensorParallelDividedBytes == 160_859_947_008
            && ClusterHardwarePrior.decodeBytesPerToken(layout) == 10_767_036_288
            && ClusterHardwarePrior.dividedDecodeFraction(layout) > 0.99)
    // The private image candidate holds the vision tower on rank 0 and stays a pipeline candidate.
    let candidate = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors,
        runtimeProfile: ClusterMiMoImageCandidate.profileID)
    checks.require("mimo tp: the image candidate's layout states no tensor-parallel facts and lists no tensor parallel",
        candidate.tensorParallel == nil && !candidate.generationModes.contains(.tensorParallel))
    // The golden layout (read from the real headers on both Macs) carries the same facts beside its recorded bytes.
    let recorded = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/mimo-v2.6-flash-mopd-2026-09-28-r1.json")))
    checks.require("mimo tp: the golden layout carries the family's tensor-parallel facts and routed experts beside the bytes the real headers recorded",
        recorded.tensorParallel == layout.tensorParallel && recorded.routedExperts == layout.routedExperts
            && recorded.layers.map(\.weights) == layout.layers.map(\.weights) && recorded.ingress == layout.ingress
            && recorded.egress == layout.egress && recorded.excluded == layout.excluded)
}

/// A product layout carries the rank's native reserve (`MiMoTensorParallelRequestBudget`):
/// its own paged history and work, the activation floor, the freed-buffer cache and eight sealed frames.
private func checkMiMoRequestAllowance(_ priced: ClusterModelLayout, configuration: Data, _ checks: PlacementChecks) throws {
    let plan = try MiMoTensorParallelPlan(configuration: configuration)
    let allowance = priced.tensorParallel?.family.requestAllowance
    let budget = try MiMoTensorParallelRequestBudget.derive(plan: plan, slidingWindow: 128, contextTokens: 65_536,
        chunkTokens: 512, allocationBound: { $0 + 16_384 })
    checks.require("mimo tp allowance: the layout quotes the rank's budget at the profile's longest request (65,536 tokens, 512-token chunks): request \(budget.requestBytes), rank \(budget.rankBytes), reserved \(budget.allowance.reservedBytes)",
        allowance == budget.allowance && allowance?.maximumContextTokens == 65_536 && allowance?.maximumChunkTokens == 512)
    checks.require("mimo tp allowance: the conservative 5.5 GiB activation floor and the 4 GiB freed-buffer cache are charged once beside the request",
        budget.rankBytes == 5_905_580_032 + 4_294_967_296 + budget.allowance.collectiveScratchBytes
            && budget.allowance.reservedBytes == budget.requestBytes + budget.rankBytes)
    checks.require("mimo tp allowance: eight sealed frames of a chunk's partial (512 x 16,384 bytes and the seal)",
        budget.allowance.maximumCollectivePayloadBytes == 512 * 16_384
            && budget.allowance.collectiveScratchBytes == 8 * (budget.allowance.maximumCollectiveFrameBytes + 16_384))
    // The planner quotes a rank at its exact shard plus that reserve.
    let devices = try [SyntheticMac.idle(256).device("a"), SyntheticMac.idle(256).device("b")]
    var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
    let rank = try ClusterPlacementPlanner.plan(devices: devices, layout: priced, policy: forced).chosen?.ranks.first
    let pages = (priced.layers.reduce(0) { $0 + $1.weights.tensorCount } + priced.ingress.tensorCount + priced.egress.tensorCount) * SyntheticMac.page
    checks.require("mimo tp quote: a rank's weights are its exact 84,013,770,176-byte shard in whole pages, and its request need covers the reserve (need \(rank?.needBytes ?? 0))",
        rank?.weightsBytes == 84_013_770_176 + pages && (rank?.requestNeedBytes ?? 0) >= budget.allowance.reservedBytes)
}

/// The fastest-plan rule on constructed pairs, under the provider's own
/// first-placement policy (`ClusterPlacementFlow.decide`: tensor parallel
/// first, an unmeasured link assumed): against the plain pipeline (1-3), then
/// as the provider plans MiMo, its speculative pipeline credited by its records (4).
/// Every tensor-parallel win the device-index prior alone predicts keeps the
/// pipeline; requests served in tensor parallel decide (MiMo's runtime takes
/// no share probe yet).
private func checkMiMoFastestPlan(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    // Each Mac's whole-model rates and device index (`qmm_h4096_b4_g64_x16_v1`). M5 Ultra 256 GB: MiMo alone on the
    // cluster path, 57 tok/s (MTP off, 2026-10-13); 1,000 prefill tok/s (none is recorded on an M5 Ultra; the plan
    // estimates 1,000-2,000). M5 Max 128 GB, which cannot hold MiMo alone: the stage probes' 0.50 ms a layer and
    // 1.19 ms over 48 layers (40 tok/s), and the M3 Ultra + M5 Max pair's 380 prefill tok/s rounded to 400.
    // Indices: the M5 Ultra's measured one; the recorded M4 Max index stands in for the M5 Max. Inputs only.
    func mac(_ label: String, _ gib: Double, chip: String, decode: Double, prefill: Double, index: (Double, Double)) throws -> ClusterPlacementDevice {
        var profile = try SyntheticMac.idle(gib).profile(chip: chip)
        profile.speedIndex = .init(chip: chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: index.1, decodeIndex: index.0)
        return .init(label: label, profile: profile, speed: measured(prefill: prefill, decode: decode))
    }
    let ultras = try ["a", "b"].map { try mac($0, 256, chip: "Apple M5 Ultra", decode: 57, prefill: 1_000, index: (46_409, 2_337_768)) }
    let maxes = try ["a", "b"].map { try mac($0, 128, chip: "Apple M5 Max", decode: 40, prefill: 400, index: (21_100, 520_000)) }
    // The pair's own probe (two M5 Ultra, keyed JACCL, 2026-10-31): sealed all-sum 29 us at 16 KB, 3,919 us at 32 MiB.
    func probe(allSum: Int, large: Int) -> ClusterLinkCosts {
        ClusterLinkCosts(probe: ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
            pointToPointSmallMicroseconds: 180, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 2_502,
            allSumSmallBytes: 16_384, allSumSmallMicroseconds: allSum, allSumLargeBytes: 32 << 20, allSumLargeMicroseconds: large),
            measuredUTC: "2026-10-31T00:00:00Z")!
    }
    let measuredLink = probe(allSum: 29, large: 3_919), slowLink = probe(allSum: 109, large: 9_000)
    func first(_ prompt: Int?, _ outputs: Int?) -> ClusterPlacementPolicy {
        var p = ClusterPlacementPolicy(); p.promptTokens = prompt; p.outputTokens = outputs
        p.tensorParallelFirst = true; p.tensorParallelAssumesUnmeasuredLink = true
        return p
    }
    func plan(_ devices: [ClusterPlacementDevice], _ policy: ClusterPlacementPolicy, _ link: ClusterLinkCosts) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
    }
    func tensor(_ r: ClusterPlacementResult) -> Bool { r.chosen?.mode == .tensorParallel && r.tensorParallel?.verdict == .chosen }
    func pipeline(_ r: ClusterPlacementResult) -> Bool {
        r.chosen.map { !$0.mode.usesTensorParallelDecode } == true && r.tensorParallel?.verdict == .predictedSlower
    }
    func predicted(_ r: ClusterPlacementResult) -> (tensor: Double, other: Double) {
        (r.tensorParallel?.tensorParallel?.prediction(.rested).requestSeconds ?? .infinity, r.tensorParallel?.bestOtherSeconds ?? .infinity)
    }
    // Predicted faster by the margin on the device-index prior alone: the best other mode is kept (the evidence rule).
    func held(_ r: ClusterPlacementResult) -> Bool {
        r.chosen.map { !$0.mode.usesTensorParallelDecode } == true && r.tensorParallel?.verdict == .predictedFasterOnPriorOnly
            && r.tensorParallel?.evidence == .priorOnly && predicted(r).tensor < predicted(r).other * 0.95
    }
    func times(_ r: ClusterPlacementResult) -> String {
        String(format: "%.2f s vs %.2f s", predicted(r).tensor, predicted(r).other)
    }

    // 1. Two M5 Max 128 GB, which cannot hold MiMo alone, default link costs: tensor parallel is predicted faster by
    // the margin for decode-heavy requests, on the device-index prior alone, so the pipeline is kept; a pipeline also
    // where tensor parallel is not predicted faster (within the margin, or the prompt's FP32 sums).
    let alone = try plan(maxes, first(128, 128), .unmeasured).alone
    checks.require("mimo fastest plan: neither M5 Max 128 GB can hold MiMo alone",
        alone.count == 2 && alone.allSatisfy { if case .never = $0.fit { return true } else { return false } })
    for (prompt, outputs) in [(128, 128), (1_024, 1_024)] {
        let result = try plan(maxes, first(prompt, outputs), .unmeasured)
        checks.require("mimo fastest plan: 2x M5 Max 128 GB, default link costs, \(prompt) + \(outputs): tensor parallel predicted faster by the margin on the prior only (\(times(result))), so the pipeline is kept",
            held(result) && result.tensorParallel?.tensorParallel?.ranks.allSatisfy({ $0.fit == .now }) == true)
    }
    let maxNearTie = try plan(maxes, first(1_024, 128), .unmeasured), nearTie = predicted(maxNearTie)
    checks.require("mimo fastest plan: 2x M5 Max 128 GB, default link costs, 1,024 + 128: a pipeline, tensor parallel faster but within the margin (\(times(maxNearTie)))",
        pipeline(maxNearTie) && nearTie.tensor < nearTie.other && nearTie.tensor > nearTie.other * 0.95)
    checks.require("mimo fastest plan: 2x M5 Max 128 GB, default link costs, 8,192 + 128: a pipeline (the prompt's sums dominate)",
        pipeline(try plan(maxes, first(8_192, 128), .unmeasured)))

    // 2. Two M5 Ultra 256 GB, default link costs: a pipeline for every request. On the assumed link 97 sums cost
    // about 10.3 ms a step, more than the weight streaming a half saves.
    for (prompt, outputs) in [(128, 128), (1_024, 128), (8_192, 128), (1_024, 1_024)] {
        let result = try plan(ultras, first(prompt, outputs), .unmeasured)
        checks.require("mimo fastest plan: 2x M5 Ultra 256 GB, default link costs, \(prompt) + \(outputs): a pipeline, tensor parallel predicted slower on the assumed link (\(times(result)))",
            pipeline(result) && result.tensorParallel?.reductionKeyed == true && !result.basis.linkCostsMeasured
                && (ClusterPlacementExplanation.deploymentReason(result) ?? "").hasPrefix("Pipeline: tensor parallel is predicted slower"))
    }
    // The choice alone holds it back: the same layout without it (a TP-first family) is placed in tensor parallel.
    let ruled = try ClusterPlacementPlanner.plan(devices: ultras, layout: try mimoTensorParallelFirst(layout),
        policy: first(8_192, 128), link: .unmeasured)
    checks.require("mimo fastest plan: without its choice the same layout, Macs and policy put tensor parallel first",
        ruled.chosen?.mode == .tensorParallel)

    // 3. A measured link moves the prediction both ways; on the prior alone it never chooses tensor parallel.
    let ultraDefault = try plan(ultras, first(1_024, 128), .unmeasured)
    let ultraMeasured = try plan(ultras, first(1_024, 128), measuredLink), ultraSlow = try plan(ultras, first(1_024, 128), slowLink)
    checks.require("mimo fastest plan: 2x M5 Ultra, 1,024 + 128: a pipeline on default costs, tensor parallel predicted faster on the pair's measured 29 us link but on the prior only (\(times(ultraMeasured))), a pipeline on a measured 109 us one",
        pipeline(ultraDefault) && held(ultraMeasured) && pipeline(ultraSlow)
            && (ClusterPlacementExplanation.deploymentReason(ultraMeasured) ?? "").hasPrefix("Pipeline: tensor parallel is predicted"))
    checks.require("mimo fastest plan: 2x M5 Ultra, 8,192 + 128, the measured 29 us link: a pipeline (the prompt's sums)",
        pipeline(try plan(ultras, first(8_192, 128), measuredLink)))
    let maxMeasured = try plan(maxes, first(1_024, 128), measuredLink)
    checks.require("mimo fastest plan: 2x M5 Max 128 GB, 1,024 + 128: a pipeline on default costs, tensor parallel predicted faster on the measured 29 us link but on the prior only (\(times(maxMeasured)))",
        pipeline(maxNearTie) && held(maxMeasured))
    // The pipeline's speculative rounds are in the comparison: credited MiMo's recorded 1.37x (pipeline_mtp_v1,
    // M5 Ultra + M3 Ultra, 2026-10-14), the speculative pipeline is what tensor parallel must beat.
    var credited = first(128, 128); credited.recordedPipelineSpeculativeFactor = 1.37
    let plain = try plan(ultras, first(128, 128), measuredLink), rounds = try plan(ultras, credited, measuredLink)
    checks.require("mimo fastest plan: 2x M5 Ultra, 128 + 128, 29 us: the pipeline credited 1.37x for its rounds is the one compared (\(times(rounds)), plain \(times(plain))) and is kept, tensor parallel predicted faster on the prior only",
        held(plain) && held(rounds) && predicted(rounds).other < predicted(plain).other * 0.8 && rounds.chosen?.mode == .pipelineMTP)
    // An automatic replacement invents no link: without a measured one, the pipeline it runs.
    var replacement = first(128, 128); replacement.tensorParallelAssumesUnmeasuredLink = false
    let kept = try plan(maxes, replacement, .unmeasured)
    checks.require("mimo fastest plan: an automatic replacement before any measured link keeps a pipeline (tensor parallel not predicted)",
        kept.chosen.map { !$0.mode.usesTensorParallelDecode } == true && kept.tensorParallel?.verdict == .reductionNotMeasured)
    // A pipeline the pair keeps holds a tensor-parallel win back under the margin it must beat, as for any mode, even
    // one requests served in tensor parallel measured (70 tok/s against the pipeline's 39).
    var keep = first(128, 128); keep.keptMode = .pipeline; keep.keptModeMargin = .infinity; keep.keptModeReason = "kept after the update"
    let servedMaxes = try afterServedTensorParallel(maxes, layout: layout, link: measuredLink, decode: 70, prompt: 128, outputs: 128)
    let keptPipeline = try plan(servedMaxes, keep, measuredLink), unkept = try plan(servedMaxes, first(128, 128), measuredLink)
    checks.require("mimo fastest plan: a kept pipeline holds tensor parallel back even on served share steps (unlike a TP-first family)",
        keptPipeline.chosen?.mode == .pipeline && keptPipeline.keptModeReason == "kept after the update" && tensor(unkept))
    // The developer setting still places it (MiMo's served records start from such a session).
    var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
    let forcedPlan = try plan(ultras, forced, .unmeasured)
    checks.require("mimo fastest plan: the developer's forced mode still places tensor parallel, with nothing measured",
        forcedPlan.chosen?.mode == .tensorParallel)
    // Tensor parallel prefills serially, the only schedule `MiMoTensorParallelResidentRuntime` loads (2026-11-03: a
    // MiMo pair planned in tensor parallel was saved with the lookahead and refused at load).
    checks.require("mimo prefill schedule: the layout lists serial and one-chunk lookahead; the forced tensor parallel and tensor parallel placed first without the choice are planned serial",
        layout.prefillSchedules == [.serial, .oneChunkLookahead] && forcedPlan.chosen?.prefillSchedule == .serial
            && ruled.chosen?.mode == .tensorParallel && ruled.chosen?.prefillSchedule == .serial)

    // 4. As the provider plans MiMo: its shipped records credit the speculative pipeline the decode speed-up they
    // measured (pipeline_mtp_v1, M5 Ultra + M3 Ultra, 2026-10-14: 59.18 against 43.05 tok/s; the provider's setup
    // checks pin that `ClusterPlacementFlow.decide` credits it), and a fresh pair plans for the layout's longest
    // request. Before a load measures the link every pair keeps the speculative pipeline, even for a short request;
    // on the measured 29 us link tensor parallel is predicted faster for that decode-heavy request on the prior
    // alone (`mainnet/mimo-tp-plan.md` makes it about a tie on 2x M5 Ultra, -22% at worst), so both keep it too.
    let recordedRounds = 59.175439562562005 / 43.05376848056872
    func asProvider(_ prompt: Int? = nil, _ outputs: Int? = nil) -> ClusterPlacementPolicy {
        var p = first(prompt, outputs); p.recordedPipelineSpeculativeFactor = recordedRounds
        return p
    }
    func speculative(_ r: ClusterPlacementResult) -> Bool {
        r.chosen?.mode == .pipelineMTP && r.tensorParallel?.verdict == .predictedSlower
    }
    for (name, devices) in [("2x M5 Max 128 GB", maxes), ("2x M5 Ultra 256 GB", ultras)] {
        let fresh = try plan(devices, asProvider(), .unmeasured), short = try plan(devices, asProvider(128, 128), .unmeasured)
        checks.require("mimo as the provider plans it: \(name) before a load measures the link keeps the speculative pipeline for a fresh pair's \(fresh.promptTokens) + \(fresh.outputTokens) (\(times(fresh))) and for 128 + 128 (\(times(short)))",
            fresh.promptTokens == 32_768 && fresh.outputTokens == 32_768 && speculative(fresh) && speculative(short))
        let fast = try plan(devices, asProvider(), measuredLink), long = try plan(devices, asProvider(8_192, 128), measuredLink)
        checks.require("mimo evidence rule: \(name) on the measured 29 us link, nothing served in tensor parallel: tensor parallel predicted faster for a fresh pair's request on the prior only (\(times(fast))), so the speculative pipeline is kept; also for 8,192 + 128 (\(times(long)))",
            held(fast) && fast.chosen?.mode == .pipelineMTP && speculative(long)
                && ClusterPlacementExplanation.tensorParallelNote(fast) == .notMeasuredYet)
        checks.require("mimo as the provider plans it: \(name) on a measured 109 us link keeps the speculative pipeline for a fresh pair's request",
            speculative(try plan(devices, asProvider(), slowLink)))
    }
    // Requests this build served in tensor parallel are MiMo's evidence: the shard rates they corrected decide against
    // the credited rounds (2x M5 Ultra: 76.8 tok/s; 2x M5 Max: 54.2).
    for (name, devices, slow, fast) in [("2x M5 Ultra 256 GB", ultras, 70.0, 95.0), ("2x M5 Max 128 GB", maxes, 45.0, 70.0)] {
        let slower = try plan(try afterServedTensorParallel(devices, layout: layout, link: measuredLink, decode: slow, prompt: 128, outputs: 128),
            asProvider(128, 128), measuredLink)
        let faster = try plan(try afterServedTensorParallel(devices, layout: layout, link: measuredLink, decode: fast, prompt: 128, outputs: 128),
            asProvider(128, 128), measuredLink)
        checks.require("mimo evidence rule: \(name), 29 us, 128 + 128, served in tensor parallel at \(Int(slow)) tok/s: the speculative pipeline on the served split (\(times(slower)))",
            speculative(slower) && slower.tensorParallel?.evidence == .measured)
        checks.require("mimo evidence rule: \(name), the same served at \(Int(fast)) tok/s: tensor parallel on the served split (\(times(faster))), and its line says so",
            tensor(faster) && faster.tensorParallel?.evidence == .measured
                && (ClusterPlacementExplanation.deploymentReason(faster) ?? "").hasSuffix(", on its own step as measured on both Macs."))
        // The setup saves the chosen candidate's prefill schedule (`ClusterPlacementSetup`): tensor parallel is planned
        // serial; the speculative pipeline keeps the lookahead.
        checks.require("mimo prefill schedule: \(name), tensor parallel chosen on served requests is planned serial, as is the assessment's best tensor-parallel candidate; the speculative pipeline keeps one chunk of lookahead",
            faster.chosen?.prefillSchedule == .serial && faster.tensorParallel?.tensorParallel?.prefillSchedule == .serial
                && slower.tensorParallel?.tensorParallel?.prefillSchedule == .serial
                && slower.chosen?.mode == .pipelineMTP && slower.chosen?.prefillSchedule == .oneChunkLookahead)
    }
    // The rule is model-neutral: a share probe would count as for any family, were MiMo's runtime to take one.
    let probed = try plan(withShareProbes(ultras, layout: layout, halfStepMicroseconds: 9_000), asProvider(128, 128), measuredLink)
    checks.require("mimo evidence rule: share probes of MiMo at 9.0 ms a half step on both Macs (its runtime records none yet) would let the measured split choose (\(times(probed)))",
        tensor(probed) && probed.tensorParallel?.evidence == .measured)
}

/// The same layout with its plan's choice removed: a family that keeps the tensor-parallel-first rule.
private func mimoTensorParallelFirst(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as? [String: Any] ?? [:]
    var tp = object["tensorParallel"] as? [String: Any] ?? [:]
    var family = tp["family"] as? [String: Any] ?? [:]
    family["choice"] = nil; tp["family"] = family; object["tensorParallel"] = tp
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

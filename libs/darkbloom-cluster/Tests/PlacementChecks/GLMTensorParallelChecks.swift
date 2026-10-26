import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// GLM-5.3 Flash in tensor parallel on two ranks, against its layout as the
/// layout command read it from the registered artifact's own tensor headers
/// (`Golden/layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json`, EigenLabs revision
/// 8841c52a, read on an M5 Ultra 2026-10-20: GLM's family needs MLX, which
/// these checks do not compile). The Macs are the recorded M5 Ultra 256 GB
/// (`pairs/m3ultra-m5ultra/profile-mac-b.json`) twice, with GLM's measured
/// single-Mac rates on it (1,856 prefill, 52.9 decode tok/s) and that Mac's
/// measured device index. Recorded inputs only: no model, no GPU.
func checkGLMTensorParallel(golden: URL, _ checks: PlacementChecks) throws {
    let file = golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")
    let layout = try ClusterModelLayout.decode(Data(contentsOf: file))
    checks.require("glm tp: the retained layout is canonical and names the registered GLM row",
        try layout.encoded() + Data([10]) == Data(contentsOf: file) && layout.runtimeModelID == "registered_glm53_flash"
            && layout.layerCount == 45)
    try checkGLMCoverage(layout, checks)
    try checkGLMActiveBytesPrior(layout, golden: golden, checks)
    try checkGLMChoice(layout, golden: golden, checks)
    let priced = try withNextN(layout)
    try checkGLMNextN(layout, priced: priced, golden: golden, checks)
    try checkGLMTensorParallelFirst(priced, golden: golden, checks)
    try checkGLMPipelineHop(layout, golden: golden, checks)
}

/// A GLM pipeline's prefill: each 2,048-token chunk's residual (the 4 x 4,096
/// stream in bfloat16, 32,768 B a token: 64 MiB) crosses the cut, priced on the
/// link probe's two record sizes (`ClusterLinkCosts.chunkHopSeconds`), not as
/// the probe's one 4 MiB record. Recorded inputs and the measured probe only.
private func checkGLMPipelineHop(_ layout: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let profile = try m5Ultra(golden)
    let devices = ["mac-a", "mac-b"].map { ClusterPlacementDevice(label: $0, profile: profile, speed: glmAlone()) }
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-14T18:00:00Z")!
    var request = ClusterPlacementPolicy(); request.promptTokens = 32_768; request.outputTokens = 1
    func first(_ link: ClusterLinkCosts) throws -> Double {
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [22], mode: .pipeline, prefillSchedule: .serial,
            layout: layout, policy: request, link: link).rested.firstTokenSeconds
    }
    let hop = link.chunkHopSeconds(bytes: layout.maximumChunkTokens * layout.boundaryBytesPerToken)
    let paid = try first(link) - first(.unmeasured)
    checks.require(String(format: "glm pipeline: a 32K prompt's 16 chunk hops of 64 MiB cost %.0f ms (as one 4 MiB record each: %.0f ms)",
            paid * 1e3, 16 * link.perChunkSeconds * 1e3),
        layout.boundaryBytesPerToken == 32_768 && layout.maximumChunkTokens == 2_048
            && abs(paid - 16 * hop) <= 1e-9 * paid && hop > 14 * link.perChunkSeconds)
}

/// The layout as this build's GLM family describes it. The retained layout was
/// read by a build whose plan left out the NextN layer the tensor-parallel
/// runtime decodes with on every rank; its plan gets the head as
/// `GLM5NextPlacementFamily.tensorParallelSpeculativeHead` states it: depth 2
/// (`GLM5NextTensorParallelResidentRuntime.mtpDepth`), the decode the pair
/// measured at depth 2 over one token per step (76.0 against 62.6 tok/s), and
/// 2 GiB standing in for the request bytes that function computes from the
/// real configuration with MLX's allocator, which these checks do not compile
/// (the NextN history at 65,536 tokens, its work, and 34 linear-attention
/// layers' captured windows: about 1.5 to 2 GB).
private let nextNRequestBytes = 2 << 30
private let nextNSpeedup = 76.0 / 62.6

private func withNextN(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    guard let tp = layout.tensorParallel else { throw ProbeError("the GLM layout carries no tensor-parallel plan") }
    let f = tp.family
    let family = ClusterTensorParallelFamilyPlan(plan: f.plan, ranks: f.ranks, reductionsPerLayer: f.reductionsPerLayer,
        reductionsPerStep: f.reductionsPerStep, partialBytesPerToken: f.partialBytesPerToken,
        layerPartialBytesPerToken: f.layerPartialBytesPerToken, stateDividesByHeads: f.stateDividesByHeads,
        shareOptions: f.shareOptions, shareUnits: f.shareUnits, requestAllowance: f.requestAllowance,
        additionalResidentBytes: f.additionalResidentBytes,
        speculativeHead: .init(depth: 2, requestBytes: nextNRequestBytes, decodeSpeedup: nextNSpeedup))
    return try layout.with(tensorParallel: .init(family: family, terms: tp.terms, layerDividedBytes: tp.layerDividedBytes,
        layerReplicatedBytes: tp.layerReplicatedBytes, ingressDividedBytes: tp.ingressDividedBytes,
        ingressReplicatedBytes: tp.ingressReplicatedBytes, egressDividedBytes: tp.egressDividedBytes,
        egressReplicatedBytes: tp.egressReplicatedBytes))
}

/// The NextN layer in the plan (2026-10-25: the plan priced no NextN bytes and
/// one token per step, so it could admit a pair the load gate then refused,
/// and it predicted decode too slow): every tensor-parallel rank holds it
/// whole, in whole pages, beside its share and carries its request state;
/// decode is credited the rounds' measured speed-up, and a request the pair
/// served is taken back to one-token steps before it corrects the shares, so
/// the next plan predicts what it served. A layout without the head plans as
/// before. Recorded inputs only.
private func checkGLMNextN(_ layout: ClusterModelLayout, priced: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    guard let head = layout.speculativeHead else {
        checks.require("glm nextn: the layout carries the NextN layer as the model's speculative head", false)
        return
    }
    checks.require("glm nextn: the head is the NextN layer the worker loads (mtp_bytes=4183320576 stored, 2,641 tensors), in no range",
        head.storedBytes == 4_183_320_576 && head.tensorCount == 2_641 && priced.tensorParallel?.family.speculativeHead?.depth == 2)
    let profile = try m5Ultra(golden)
    let devices = ["mac-a", "mac-b"].map { ClusterPlacementDevice(label: $0, profile: profile, speed: glmAlone()) }
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-14T18:00:00Z")!
    var request = ClusterPlacementPolicy(); request.promptTokens = 1_024; request.outputTokens = 1_024
    func tensor(_ layout: ClusterModelLayout, _ devices: [ClusterPlacementDevice]) throws -> ClusterPlacementCandidate {
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
            layout: layout, policy: request, link: link)
    }
    let before = try tensor(layout, devices), after = try tensor(priced, devices)
    let pages = head.loadedBytes + head.tensorCount * profile.memory.pageSizeBytes
    checks.require("glm nextn: each rank holds the NextN layer whole beside its share, each tensor in whole pages (+\(pages) bytes)",
        before.ranks.count == 2 && zip(before.ranks, after.ranks).allSatisfy { $1.weightsBytes == $0.weightsBytes + pages })
    checks.require("glm nextn: each rank's request need carries the head's request state",
        zip(before.ranks, after.ranks).allSatisfy { $1.requestNeedBytes == $0.requestNeedBytes + nextNRequestBytes })
    checks.require("glm nextn: so each rank needs both more before it loads",
        zip(before.ranks, after.ranks).allSatisfy { $1.needBytes == $0.needBytes + pages + nextNRequestBytes })
    checks.require("glm nextn: decode is credited the rounds' measured speed-up over one token per step, the first token unchanged",
        abs(after.rested.decodeTokensPerSecond / before.rested.decodeTokensPerSecond - nextNSpeedup) < 1e-9
            && after.rested.firstTokenSeconds == before.rested.firstTokenSeconds)
    checks.require("glm nextn: a pipeline holds no NextN layer and keeps its prediction",
        try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [22], mode: .pipeline, prefillSchedule: .serial, layout: priced,
            policy: request, link: link) == ClusterPlacementPlanner.evaluate(devices: devices, cuts: [22], mode: .pipeline,
                prefillSchedule: .serial, layout: layout, policy: request, link: link))
    checks.require("glm nextn: the layout's description says so",
        ClusterPlacementExplanation.layout(priced).contains { $0.contains("speculative rounds of up to 2 proposals") && $0.contains("1.21x") }
            && !ClusterPlacementExplanation.layout(layout).contains { $0.contains("speculative rounds") })

    // Macs that admit the share without the NextN layer but not with it: the plan no longer admits them now, as the
    // load gate (which charges the layer, its history and its windows) would not.
    let between = before.ranks[0].needBytes + (after.ranks[0].needBytes - before.ranks[0].needBytes) / 2
    let tight = try ["mac-a", "mac-b"].map {
        ClusterPlacementDevice(label: $0, profile: try profile.cappedForBench(admissibleBytes: between), speed: glmAlone())
    }
    checks.require("glm nextn: on Macs that admit the share but not the NextN layer beside it, tensor parallel does not fit now",
        try tensor(layout, tight).ranks.allSatisfy { $0.fit == .now } && tensor(priced, tight).ranks.allSatisfy { $0.fit != .now })
    var rule = ClusterPlacementPolicy(); rule.tensorParallelFirst = true; rule.tensorParallelAssumesUnmeasuredLink = true
    let squeezed = try ClusterPlacementPlanner.plan(devices: tight, layout: priced, policy: rule, link: link)
    checks.require("glm nextn: there a split that loads now goes first (\(squeezed.chosen?.mode.rawValue ?? "none"))",
        squeezed.chosen.map { !$0.mode.usesTensorParallelDecode && $0.tier == 0 } ?? true)

    // A request served 10 % faster than predicted: the next plan predicts what it served. The rounds' speed-up comes
    // out of the served rate as out of the prediction before the shares are corrected; otherwise the reductions, a
    // one-token step's cost, would be taken from a token's time in rounds.
    let observed = after.rested.decodeTokensPerSecond * 1.1
    let sample = ClusterServedSample(route: .pair, member: nil, promptTokens: 1_024, outputTokens: 1_024,
        firstTokenSeconds: after.rested.firstTokenSeconds, decodeTokensPerSecond: observed, finishedAt: 1)
    let derived = try ClusterServedCalibration.measurements([sample], placement: .init(devices: devices, cuts: [], mode: .tensorParallel,
        schedule: .serial, layout: priced, link: link), runtimeBinarySHA256: "served", measuredUTC: "2026-10-25T00:00:00Z")
    let speeds = ClusterSpeedEstimator.estimate(devices: devices.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
        artifactSHA256: priced.artifactSHA256, promptTokens: 1_024, measurements: derived)
    let calibrated = try tensor(priced, zip(devices, speeds).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) })
    checks.require(String(format: "glm nextn: a request served at %.1f tok/s against %.1f predicted makes the next prediction %.1f",
            observed, after.rested.decodeTokensPerSecond, calibrated.rested.decodeTokensPerSecond),
        derived.count == 2 && abs(calibrated.rested.decodeTokensPerSecond / observed - 1) < 1e-6)
}

/// Tensor parallel goes first wherever it fits (`ClusterPlacementPolicy.tensorParallelFirst`, the product's rule),
/// so two M5 Ultra 256 GB plan GLM-5.3 Flash as tensor parallel on equal shares (1:1) with the NextN layer priced:
/// on a new pair, before any load measured the link (on the assumed keyed reduction); after its first load's keyed
/// probe; and as an automatic replacement, which prices only the measured link. Each pair serves it with eight lanes
/// (`DistributedInstalledPlan.tensorParallelBatchLanes`, pinned in the provider's lane tests).
private func checkGLMTensorParallelFirst(_ priced: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let profile = try m5Ultra(golden)
    checks.require("glm tp first: the recorded Mac is an M5 Ultra with 256 GB",
        profile.chip == "Apple M5 Ultra" && profile.physicalMemoryBytes == 256 << 30)
    let devices = ["mac-a", "mac-b"].map { ClusterPlacementDevice(label: $0, profile: profile, speed: glmAlone()) }
    let measured = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-14T18:00:00Z")!
    var first = ClusterPlacementPolicy(); first.tensorParallelFirst = true; first.tensorParallelAssumesUnmeasuredLink = true
    var replacement = first; replacement.tensorParallelAssumesUnmeasuredLink = false
    for (name, policy, link) in [("a new pair, link not measured yet", first, ClusterLinkCosts.unmeasured),
                                 ("after the first load's keyed probe", first, measured),
                                 ("an automatic replacement on the measured link", replacement, measured)] {
        let chosen = try ClusterPlacementPlanner.plan(devices: devices, layout: priced, policy: policy, link: link).chosen
        checks.require("glm tp first, 2x M5 Ultra 256 GB, \(name): tensor parallel 1:1, both ranks fit now",
            chosen?.mode == .tensorParallel && chosen?.tensorShares == nil && chosen?.shares == nil && chosen?.ranks.count == 2
                && chosen?.ranks.allSatisfy({ $0.fit == .now }) == true)
    }
}

/// The plan's terms, and every tensor a text stage loads counted once,
/// divided or replicated; the NextN layer and the vision tower in no rank.
private func checkGLMCoverage(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    guard let tp = layout.tensorParallel else {
        checks.require("glm tp: the layout carries the family's tensor-parallel plan", false)
        return
    }
    checks.require("glm tp: plan glm5_next_heads_and_expert_channels_v1 on 2 ranks, bfloat16 partials of the 4096 residual (the projections' outputs, summed in float32), state whole on each rank",
        tp.family.plan == "glm5_next_heads_and_expert_channels_v1" && tp.family.ranks == [2]
            && tp.family.partialBytesPerToken == 4096 * 2 && !tp.family.stateDividesByHeads
            && tp.family.shareOptions == nil && tp.family.shareUnits == nil && tp.terms == .current
            && layout.generationModes == [.pipeline, .tensorParallel])
    checks.require("glm tp: two sums per layer (attention, feed-forward) and one per step (token and stop flags): 91 per decode step",
        tp.family.reductionsPerLayer == 2 && tp.family.reductionsPerStep == 1 && tp.reductionsPerStep(layerCount: layout.layerCount) == 91)
    let layersCovered = zip(zip(tp.layerDividedBytes, tp.layerReplicatedBytes), layout.layers).allSatisfy { pair, layer in
        pair.0 > 0 && pair.1 > 0 && pair.0 + pair.1 == layer.weights.loadedBytes
    }
    checks.require("glm tp: every text layer's loaded bytes are divided or replicated exactly once, each layer both",
        layersCovered)
    checks.require("glm tp: the embedding, final norm and head are replicated whole",
        tp.ingressDividedBytes == 0 && tp.ingressReplicatedBytes == layout.ingress.loadedBytes
            && tp.egressDividedBytes == 0 && tp.egressReplicatedBytes == layout.egress.loadedBytes)
    // 114,160 stored tensors: 2,641 of the NextN layer and 347 of the vision tower in no text stage.
    let counted = layout.layers.reduce(0) { $0 + $1.weights.tensorCount } + layout.ingress.tensorCount + layout.egress.tensorCount
    checks.require("glm tp: all 111,172 text tensors are in a range, the 2,988 NextN and vision tensors in none",
        counted == 111_172 && layout.excluded.tensorCount == 2_988
            && layout.speculativeHead?.tensorCount == 2_641 && layout.excluded.storedBytes == 4_183_320_576 + 1_127_254_016)
    let divided = Double(tp.layerDividedBytes.reduce(0, +)), whole = Double(layout.layers.reduce(0) { $0 + $1.weights.loadedBytes })
    checks.require("glm tp: about 99% of the layers' bytes divide (every routed expert's channels), so a rank holds about half",
        divided / whole > 0.98 && divided / whole < 1)
}

private func m5Ultra(_ golden: URL) throws -> ClusterDeviceProfile {
    var profile = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("pairs/m3ultra-m5ultra/profile-mac-b.json")))
    // The M5 Ultra's measured device index (2026-10-14, as in the auto-choice checks).
    profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: 2_337_768, decodeIndex: 46_409)
    try profile.validate()
    return profile
}

/// GLM alone on one M5 Ultra, measured: 1,856 prefill and 52.9 decode tok/s.
private func glmAlone() -> ClusterDeviceSpeed {
    .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: 1_856, decodeTokensPerSecond: 52.9),
          sustained: nil, explanation: "GLM-5.3 Flash alone on an M5 Ultra 256 GB")
}

/// A decode step reads 8 of the 288 routed experts per layer, not all of
/// them, and each rank reads its replicated bytes whole: the prior predicts
/// less than a perfect halving of the step for GLM's decode.
private func checkGLMActiveBytesPrior(_ layout: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    guard let experts = layout.routedExperts, let tp = layout.tensorParallel else {
        checks.require("glm tp: the layout carries GLM's routed experts", false)
        return
    }
    let every = layout.layers.reduce(0) { $0 + $1.weights.loadedBytes } + layout.egress.loadedBytes
    let active = ClusterHardwarePrior.decodeBytesPerToken(layout)
    checks.require("glm tp: routing 8 of 288 experts; a decode step reads the rest whole and 8/288 of the routed experts",
        experts.routing == .init(selected: 8, experts: 288)
            && active == every - experts.loadedBytes + (experts.loadedBytes * 8 + 287) / 288)
    checks.require("glm tp: so a decode step reads under 6% of the 186 GB the layers and head hold (it read all of them before)",
        Double(active) / Double(every) < 0.06 && active > 9_000_000_000)
    let fraction = ClusterHardwarePrior.dividedDecodeFraction(layout)
    let replicatedRead = Double(tp.layerReplicatedBytes.reduce(0, +) - (experts.loadedBytes - experts.tensorParallelDividedBytes!)
        + tp.egressReplicatedBytes) + Double(experts.activeBytes(experts.loadedBytes - experts.tensorParallelDividedBytes!))
    checks.require("glm tp: of the bytes a step reads, the replicated ones (router, latent projections, indexer, head) do not divide",
        fraction < 0.95 && fraction > 0.85 && abs((1 - fraction) * Double(active) - replicatedRead) < 2)
    let profile = try m5Ultra(golden)
    let rates = glmAlone().rested
    let split = ClusterDecodeSplit(rates: rates,
        hardwareWeightSeconds: ClusterHardwarePrior.weightSeconds(profile: profile, layout: layout),
        hardwareDividedFraction: fraction)
    let whole = 1 / rates.decodeTokensPerSecond
    checks.require("glm tp: from the M5 Ultra's measured hardware a half steps in more than half the measured whole step (no perfect 2x)",
        split.fromHardware == true && split.shareStepSeconds(ranks: 2) > whole / 2 * 1.05 && split.shareStepSeconds(ranks: 2) < whole)
    // Index-only rates (nothing of GLM measured): still not a perfect halving.
    if let estimate = ClusterHardwarePrior.absoluteRates(profile: profile, layout: layout) {
        let prior = ClusterDecodeSplit(rates: estimate,
            hardwareWeightSeconds: ClusterHardwarePrior.weightSeconds(profile: profile, layout: layout), hardwareDividedFraction: fraction)
        checks.require("glm tp: from the device index alone a half is not predicted at twice the whole model's decode",
            prior.shareStepSeconds(ranks: 2) > prior.wholeStepSeconds / 2 * 1.05)
    } else {
        checks.require("glm tp: the M5 Ultra's index gives absolute GLM rates", false)
    }
}

/// Two identical M5 Ultras with GLM measured alone and the keyed link
/// measured choose tensor parallel (measured: 56 against 41 tok/s decode
/// for the pipeline); with the link not yet measured, a pipeline, and the
/// line says the first load measures it.
private func checkGLMChoice(_ layout: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let profile = try m5Ultra(golden)
    let devices = ["mac-a", "mac-b"].map { ClusterPlacementDevice(label: $0, profile: profile, speed: glmAlone()) }
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-14T18:00:00Z")!
    var decodeHeavy = ClusterPlacementPolicy(); decodeHeavy.promptTokens = 1_024; decodeHeavy.outputTokens = 1_024
    for (name, policy) in [("the row's full request (32K + 32K)", ClusterPlacementPolicy()), ("1K + 1K", decodeHeavy)] {
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        let chosen = result.chosen
        let why = ClusterPlacementExplanation.deploymentReason(result)
        FileHandle.standardError.write(Data("glm tp 2x M5 Ultra \(name): \(why ?? "-")\n".utf8))
        checks.require("glm tp 2x M5 Ultra 256 GB, keyed link measured, \(name): tensor parallel is chosen and both ranks fit at rest",
            chosen?.mode == .tensorParallel && result.tensorParallel?.verdict == .chosen
                && chosen?.ranks.count == 2 && chosen?.ranks.allSatisfy({ $0.hardwareFits == true && $0.fit.possible }) == true)
        checks.require("glm tp 2x M5 Ultra, \(name): each rank holds about half the weights, not the whole model",
            chosen?.ranks.allSatisfy({ Double($0.weightsBytes) < Double(layout.wholeModelLoadedBytes) * 0.52 }) == true)
        checks.require("glm tp 2x M5 Ultra, \(name): the setup line says tensor parallel, against a pipeline",
            why.map { $0.hasPrefix("Tensor parallel") && $0.contains("pipeline") } == true)
    }
    let unmeasured = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, link: .unmeasured)
    let why = ClusterPlacementExplanation.deploymentReason(unmeasured)
    FileHandle.standardError.write(Data("glm tp 2x M5 Ultra, link unmeasured: \(why ?? "-")\n".utf8))
    checks.require("glm tp 2x M5 Ultra, link not measured yet: a pipeline, tensor parallel waiting for the keyed reduction's measurement",
        unmeasured.chosen?.mode == .pipeline && unmeasured.tensorParallel?.verdict == .reductionNotMeasured
            && unmeasured.chosen?.ranks.count == 2)
    checks.require("glm tp 2x M5 Ultra, link not measured: the line says the link is measured at the first load",
        why == "Pipeline: the link between the Macs has not been measured yet, so tensor parallel is not predicted; the first load measures it.")
}

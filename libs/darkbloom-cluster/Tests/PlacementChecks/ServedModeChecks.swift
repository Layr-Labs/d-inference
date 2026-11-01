import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The M5 Ultra pair's re-plan after a Darkbloom update (2026-10-22): the
/// control leader planned GLM-5.3 Flash again with the other Mac's memory as
/// its report sampled it before its old tensor-parallel part stopped, so that
/// Mac's tensor-parallel share looked short "now" and a pipeline was chosen at
/// half the speed. Checked here on GLM's recorded layout and the recorded M5
/// Ultra profile: what a held part does to the choice and how the plan says
/// it; the mode a plan keeps (`ClusterPlacementPolicy.keptMode`); and what the
/// pair served in each mode, read so that requests that shared the pair do not
/// make a mode look slow (`ClusterServedModes`). Recorded inputs only.
func checkServedModes(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    let recorded = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("pairs/m3ultra-m5ultra/profile-mac-b.json")))
    func mac(_ label: String, _ memory: SyntheticMac) throws -> ClusterPlacementDevice {
        var profile = try ClusterDeviceProfile(chip: recorded.chip, performanceCores: recorded.performanceCores,
            efficiencyCores: recorded.efficiencyCores, gpuCores: recorded.gpuCores, osVersion: recorded.osVersion,
            osBuild: recorded.osBuild, physicalMemoryBytes: recorded.physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: recorded.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: recorded.gpuMaximumBufferBytes,
            allocatorLimitBytes: recorded.allocatorLimitBytes, memory: .gate(memory.observation, now: SyntheticMac.now),
            power: recorded.power, wiredLimitBytes: recorded.wiredLimitBytes)
        // The M5 Ultra's measured device index (2026-10-14), as the GLM tensor-parallel checks give it.
        profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 2_337_768, decodeIndex: 46_409)
        return .init(label: label, profile: profile, speed: .init(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 1_856, decodeTokensPerSecond: 52.9), sustained: nil,
            explanation: "GLM-5.3 Flash alone on an M5 Ultra 256 GB"))
    }
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-14T18:00:00Z")!
    var policy = ClusterPlacementPolicy(); policy.promptTokens = 1_024; policy.outputTokens = 1_024
    let rested = SyntheticMac.idle(256)
    // The other Mac as its report sampled it with its old part loaded: 100 GiB wired by the part, 110 GiB free.
    let holding = SyntheticMac(physicalGiB: 256, freeGiB: 110, inactiveCacheGiB: 22, wiredGiB: 100)
    let fresh = try [mac("mac-b", rested), mac("mac-a", rested)]
    let stale = try [mac("mac-b", rested), mac("mac-a", holding)]

    // What a held part does: the tensor-parallel share is short now, a pipeline loads now and goes first.
    let atRest = try ClusterPlacementPlanner.plan(devices: fresh, layout: layout, policy: policy, link: link)
    let held = try ClusterPlacementPlanner.plan(devices: stale, layout: layout, policy: policy, link: link)
    let need = atRest.chosen?.ranks.first?.needBytes ?? 0
    checks.require("update re-plan: the premise: both Macs at rest choose tensor parallel, and the old part leaves the other Mac short of its share",
        atRest.chosen?.mode == .tensorParallel && stale[1].profile.memory.admissibleNowBytes < need
            && fresh[1].profile.memory.admissibleNowBytes > need)
    checks.require("update re-plan: priced with the old part still loaded, a pipeline is chosen (the bug's input, not the planner's error)",
        held.chosen?.mode == .pipeline && held.tensorParallel?.tensorParallel?.tier ?? 0 > 0)
    let heldWhy = ClusterPlacementExplanation.deploymentReason(held) ?? ""
    checks.require("update re-plan: the plan says tensor parallel is faster but does not fit as the Macs are now, naming the Mac; never a qualification refusal",
        held.tensorParallel?.verdict == .doesNotFit && heldWhy.hasPrefix("Pipeline: tensor parallel is predicted")
            && heldWhy.contains("does not fit as these Macs are now") && heldWhy.contains("mac-a needs")
            && !heldWhy.contains("policy admits no"))

    // The kept mode: within its hardware group, another mode goes first only by the margin; memory still comes first.
    var keepPipeline = policy; keepPipeline.keptMode = .pipeline; keepPipeline.keptModeMargin = .infinity
    keepPipeline.keptModeReason = "kept after the update"
    let kept = try ClusterPlacementPlanner.plan(devices: fresh, layout: layout, policy: keepPipeline, link: link)
    checks.require("kept mode: a kept pipeline stays chosen over a faster tensor parallel in the same hardware group, and the plan says why",
        kept.chosen?.mode == .pipeline && kept.keptModeReason == "kept after the update"
            && ClusterPlacementExplanation.deploymentReason(kept) == "Pipeline: kept after the update."
            && kept.alternatives.contains { $0.mode == .tensorParallel })
    var byMargin = keepPipeline; byMargin.keptModeMargin = ClusterServedModes.margin
    let tpSeconds = atRest.chosen?.rested.requestSeconds ?? 0
    let pipelineSeconds = atRest.alternatives.first { $0.mode == .pipeline }?.rested.requestSeconds ?? 0
    let overtaken = try ClusterPlacementPlanner.plan(devices: fresh, layout: layout, policy: byMargin, link: link)
    checks.require("kept mode: with the margin, a mode predicted more than the margin faster goes ahead, and nothing is said about keeping",
        tpSeconds < pipelineSeconds * (1 - ClusterServedModes.margin)
            && overtaken.chosen?.mode == .tensorParallel && overtaken.keptModeReason == nil)
    var keepTP = policy; keepTP.keptMode = .tensorParallel; keepTP.keptModeMargin = .infinity
    let keptButHeld = try ClusterPlacementPlanner.plan(devices: stale, layout: layout, policy: keepTP, link: link)
    checks.require("kept mode: a kept mode that does not load now is passed by one that does (memory first)",
        keptButHeld.chosen?.mode == .pipeline && keptButHeld.keptModeReason == nil)
    let keptAndFirst = try ClusterPlacementPlanner.plan(devices: fresh, layout: layout, policy: keepTP, link: link)
    checks.require("kept mode: a kept mode the planner chose anyway is the same plan, with no reason added",
        keptAndFirst.chosen == atRest.chosen && keptAndFirst.keptModeReason == nil
            && keptAndFirst == atRest)

    // What the pair served, per mode, read at its fast end: the M5 Ultra pair's records of 2026-10-22, tensor
    // parallel served alone at about 90 tok/s and then with eight lanes sharing the pair at about 12 each.
    let pair = ["mac-b", "mac-a"]
    func entry(_ mode: ClusterGenerationMode, _ cut: String, prompt: Int, output: Int, first: Double, decode: Double) -> ClusterServedSpeedRecords.Entry {
        .init(setup: .init(modelID: "glm", mode: mode.rawValue, cut: cut, ranks: pair),
              sample: .init(route: .pair, member: nil, promptTokens: prompt, outputTokens: output, firstTokenSeconds: first,
                            decodeTokensPerSecond: decode, finishedAt: 1))
    }
    let alone = (0..<10).map { entry(.tensorParallel, "0-45|0-45", prompt: 28, output: 256, first: 0.095, decode: 90 + Double($0)) }
    let lanes = (0..<22).map { entry(.tensorParallel, "0-45|0-45", prompt: 30, output: 256, first: 0.5, decode: 11 + Double($0) / 10) }
    let pipeline = (0..<32).map { entry(.pipeline, "0-24|24-45", prompt: 60, output: 256, first: 0.42, decode: 46 + Double($0 % 4)) }
    let served = alone + lanes + pipeline
    let figures = ClusterServedModes.figures(served, promptTokens: 60, outputTokens: 256)
    let tpFigure = figures.first { $0.mode == .tensorParallel }, pipelineFigure = figures.first { $0.mode == .pipeline }
    let medianTP = (alone + lanes).compactMap(\.sample.decodeTokensPerSecond).sorted()[16]
    checks.require("served modes: requests that shared the pair do not set a mode's figure (the median would have read 12 tok/s)",
        medianTP < 20 && (tpFigure?.decodeTokensPerSecond ?? 0) > 85 && (pipelineFigure?.decodeTokensPerSecond ?? 0) >= 48
            && tpFigure?.samples == 32 && figures.first?.mode == .tensorParallel)
    checks.require("served modes: tensor parallel served faster than the pipeline by the margin",
        ClusterServedModes.servedFaster(figures)?.faster.mode == .tensorParallel)
    let thin = ClusterServedModes.figures(Array(alone.prefix(2)) + pipeline, promptTokens: 60, outputTokens: 256)
    checks.require("served modes: fewer than \(ClusterServedModes.minimumSamples) requests of a setup make no figure",
        thin.map(\.mode) == [.pipeline] && ClusterServedModes.servedFaster(thin) == nil)
    let modes: [ClusterGenerationMode] = [.pipeline, .tensorParallel]
    let afterUpdate = ClusterServedModes.hold(incumbent: .tensorParallel, figures: figures, plannable: modes, promptTokens: 60, outputTokens: 256)
    checks.require("served modes: after an update, a mode the pair served faster is kept whatever the planner predicts",
        afterUpdate?.mode == .tensorParallel && afterUpdate?.margin == .infinity
            && afterUpdate?.reason.contains("this pair served tensor parallel") == true)
    let pipelineBefore = ClusterServedModes.hold(incumbent: .pipeline, figures: figures, plannable: modes, promptTokens: 60, outputTokens: 256)
    checks.require("served modes: after an update, a mode the pair served slower is kept unless the planner predicts the other the margin faster",
        pipelineBefore?.mode == .pipeline && pipelineBefore?.margin == ClusterServedModes.margin)
    let onlyOne = ClusterServedModes.hold(incumbent: .tensorParallel, figures: [tpFigure!], plannable: modes, promptTokens: 60, outputTokens: 256)
    checks.require("served modes: after an update, a pair that never served another mode keeps its own whenever it loads",
        onlyOne?.mode == .tensorParallel && onlyOne?.margin == .infinity && onlyOne?.reason.contains("has not served another mode") == true)
    let manual = ClusterServedModes.hold(incumbent: nil, figures: figures, plannable: modes, promptTokens: 60, outputTokens: 256)
    checks.require("served modes: any plan of a pair that served both modes keeps the one it served faster",
        manual?.mode == .tensorParallel && manual?.margin == .infinity && manual?.reason.hasSuffix("chosen over the planner's prediction") == true)
    let close = alone.map { entry(.tensorParallel, "0-45|0-45", prompt: 60, output: 256, first: 0.42, decode: $0.sample.decodeTokensPerSecond! / 2) }
    checks.require("served modes: a race within the margin keeps nothing on a plan that is not after an update",
        ClusterServedModes.hold(incumbent: nil, figures: ClusterServedModes.figures(close + pipeline, promptTokens: 60, outputTokens: 256),
            plannable: modes, promptTokens: 60, outputTokens: 256) == nil)
    checks.require("served modes: a mode this build cannot place is neither kept nor compared",
        ClusterServedModes.hold(incumbent: .tensorParallel, figures: figures, plannable: [.pipeline], promptTokens: 60, outputTokens: 256) == nil
            && ClusterServedModes.hold(incumbent: nil, figures: figures, plannable: [.pipeline], promptTokens: 60, outputTokens: 256) == nil)
    // End to end on the planner: the pipeline-kept plan above, but the pair served tensor parallel faster.
    var served2 = policy
    if let hold = ClusterServedModes.hold(incumbent: .pipeline, figures: figures, plannable: modes, promptTokens: 1_024, outputTokens: 1_024) {
        served2.keptMode = hold.mode; served2.keptModeMargin = hold.margin; served2.keptModeReason = hold.reason
    }
    let switched = try ClusterPlacementPlanner.plan(devices: fresh, layout: layout, policy: served2, link: link)
    checks.require("served modes: after an update from a pipeline, tensor parallel is chosen when the planner and the served requests both find it faster",
        switched.chosen?.mode == .tensorParallel && switched.keptModeReason == nil)
}

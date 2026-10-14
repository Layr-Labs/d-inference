import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// On a NEW pair the planner chooses tensor parallel or a pipeline by itself
/// (owner rule 2026-10-14: detect hardware -> pick model -> memory check ->
/// planner picks): a share's step is predicted from the Mac's own measured
/// hardware (its device index's bytes per second and the measured whole-model
/// step: `ClusterHardwarePrior`), never "a share steps as slowly as the whole
/// model"; the request the pair serves (decode-heavy or prompt-heavy) decides;
/// the setup screen says why in one line. Constructed Macs: the index figures
/// are inputs scaled from the M5 Ultra's measured index (46,409 decode and
/// 2,337,768 prefill operations per second, 2026-10-14) by nominal bandwidth,
/// not claims about those machines. No model, no GPU, no network: not a
/// hardware pass.
func checkAutoChoice(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let layout = try executing(big, [.tensorParallel])
    try checkPriorArithmetic(layout, checks)
    try checkNewPairs(layout, checks)
    try checkRecordedPairWithoutProbes(layout, golden: golden, checks)
    try checkServedReplacesPrior(layout, checks)
    try checkRequestMix(layout, checks)
}

/// The product's sealed all-sum as the link probe measured it on the
/// Thunderbolt 5 pair (73-101 us at a decode step's 20 KB; about 4 ms at a
/// 512-token chunk), and its records.
private func productProbe() -> ClusterLinkCosts {
    ClusterLinkCosts(probe: rdmaProbe(allSumSmallMicroseconds: 85, allSumLargeMicroseconds: 4_000), measuredUTC: "2026-10-14T18:00:00Z")!
}

private func indexed(_ mac: SyntheticMac, chip: String, decodeIndex: Double, prefillIndex: Double) throws -> ClusterDeviceProfile {
    var profile = try mac.profile(chip: chip)
    profile.speedIndex = .init(chip: chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: prefillIndex, decodeIndex: decodeIndex)
    try profile.validate()
    return profile
}

private func policy(prompt: Int, outputs: Int) -> ClusterPlacementPolicy {
    var p = ClusterPlacementPolicy(); p.promptTokens = prompt; p.outputTokens = outputs
    return p
}

private func checkPriorArithmetic(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    checks.require("auto choice: the index benchmark's bytes per operation come from its name (4096 x 4096 4-bit words + bf16 scale and bias per 64)",
        ClusterHardwarePrior.bytesPerOperation(benchmark: "qmm_h4096_b4_g64_x16_v1") == 9_437_184
            && ClusterHardwarePrior.bytesPerOperation(benchmark: "matmul_other_v2") == nil)
    let profile = try indexed(.idle(128), chip: "Apple M4 Max", decodeIndex: 21_100, prefillIndex: 600_000)
    let weight = ClusterHardwarePrior.weightSeconds(profile: profile, layout: layout) ?? 0
    let expected = Double(ClusterHardwarePrior.decodeBytesPerToken(layout)) / (21_100 * 9_437_184)
    checks.require("auto choice: a decode step's weight seconds are the step's weight bytes at the index's decode bytes per second",
        abs(weight - expected) < 1e-12 && weight > 0)
    // Measured whole step longer than the weight part: the rest is the floor.
    let whole = weight * 1.5
    let split = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / whole), hardwareWeightSeconds: weight)
    checks.require("auto choice: without a shard probe a half steps in floor + half the weight part (not the whole step), labelled from hardware",
        split.fromHardware == true && !split.measured && abs(split.floorSeconds - weight * 0.5) < 1e-12
            && abs(split.shareStepSeconds(fraction: 0.5) - weight) < 1e-12 && split.shareStepSeconds(fraction: 0.5) < whole)
    // A weight part longer than the measured step (the index's small operations): the whole step divides.
    let fast = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / (weight / 2)), hardwareWeightSeconds: weight)
    checks.require("auto choice: the weight part is never more than the measured whole step",
        abs(fast.weightSeconds - weight / 2) < 1e-12 && fast.floorSeconds == 0)
    let probed = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / whole,
        tensorShardDecodeTokensPerSecond: 1 / (whole * 0.95)), hardwareWeightSeconds: weight)
    checks.require("auto choice: a measured shard probe wins over the hardware prior",
        probed.measured && probed.fromHardware == nil && abs(probed.shareStepSeconds(fraction: 0.5) - whole * 0.95) < 1e-12)
    checks.require("auto choice: without an index nothing changes (no gain assumed, as before)",
        ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / whole)).fromHardware == nil)
    let rates = ClusterHardwarePrior.absoluteRates(profile: profile, layout: layout)
    checks.require("auto choice: absolute rates from the index alone: weight bytes per token over the index's bytes per second at each shape",
        rates.map { abs($0.decodeTokensPerSecond - 1 / expected) < 1e-9
            && abs($0.prefillTokensPerSecond - 600_000 * 9_437_184 / Double(ClusterHardwarePrior.decodeBytesPerToken(layout))) < 1e-6 } == true)
}

private struct NewMac {
    let gib: Double; let chip: String; let decodeIndex: Double; let prefillIndex: Double
}

/// What a fresh pair's onboarding plans with: two detected profiles with their
/// measured indices, speeds only as the estimator gives them (ratios), the
/// link the probe measured, no shard probe and nothing served.
private func freshPair(_ a: NewMac, _ b: NewMac, layout: ClusterModelLayout) throws -> [ClusterPlacementDevice] {
    let profiles = [try indexed(.idle(a.gib), chip: a.chip, decodeIndex: a.decodeIndex, prefillIndex: a.prefillIndex),
                    try indexed(.idle(b.gib), chip: b.chip, decodeIndex: b.decodeIndex, prefillIndex: b.prefillIndex)]
    let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.chip, osBuild: $0.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: [], indices: profiles.compactMap(\.speedIndex))
    return zip(["a", "b"], zip(profiles, speeds)).map { .init(label: $0.0, profile: $0.1.0, speed: $0.1.1) }
}

private func pipelined(_ c: ClusterPlacementCandidate?) -> Bool { c.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true }

private func checkNewPairs(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let link = productProbe()
    let m4max64 = NewMac(gib: 64, chip: "Apple M4 Max", decodeIndex: 21_100, prefillIndex: 520_000)
    let m4max128 = NewMac(gib: 128, chip: "Apple M4 Max", decodeIndex: 21_100, prefillIndex: 520_000)
    let m2ultra = NewMac(gib: 192, chip: "Apple M2 Ultra", decodeIndex: 30_900, prefillIndex: 450_000)
    let m1max = NewMac(gib: 64, chip: "Apple M1 Max", decodeIndex: 15_500, prefillIndex: 230_000)
    let m2max = NewMac(gib: 96, chip: "Apple M2 Max", decodeIndex: 15_500, prefillIndex: 260_000)
    let decodeHeavy = policy(prompt: 128, outputs: min(128, layout.maximumOutputTokens))
    for (name, a, b) in [("2x M4 Max 64 GB", m4max64, m4max64), ("2x M4 Max 128 GB", m4max128, m4max128),
                         ("M4 Max 64 GB + M4 Max 128 GB", m4max64, m4max128), ("2x M2 Ultra 192 GB", m2ultra, m2ultra),
                         ("M1 Max 64 GB + M2 Max 96 GB", m1max, m2max)] {
        let devices = try freshPair(a, b, layout: layout)
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: decodeHeavy, link: link)
        let tp = result.tensorParallel
        checks.require("auto choice \(name), fresh pair, decode-heavy (128 + 128): tensor parallel, predicted from each Mac's measured hardware",
            result.chosen?.mode == .tensorParallel && tp?.verdict == .chosen
                && tp?.devices.allSatisfy({ $0.split.fromHardware == true }) == true)
        let why = ClusterPlacementExplanation.deploymentReason(result)
        checks.require("auto choice \(name): the setup screen says why in one line (tensor parallel, against a pipeline, for this request)",
            why.map { $0.hasPrefix("Tensor parallel") && $0.contains("pipeline") && !$0.contains("\n") && $0.count <= 240 } == true)
        // Prompt-heavy: whatever is chosen is the faster prediction of the two modes.
        let heavy = try ClusterPlacementPlanner.plan(devices: devices, layout: layout,
            policy: policy(prompt: layout.maximumPromptTokens, outputs: min(128, layout.maximumOutputTokens)), link: link)
        let other = heavy.tensorParallel?.bestOtherSeconds ?? .infinity
        let tpSeconds = heavy.tensorParallel?.tensorParallel?.prediction(.rested).requestSeconds ?? .infinity
        checks.require("auto choice \(name), prompt-heavy (\(layout.maximumPromptTokens) + 128): the mode predicted faster (by the margin for tensor parallel) is chosen",
            heavy.chosen?.mode == .tensorParallel ? tpSeconds < other * 0.95 : pipelined(heavy.chosen) && tpSeconds >= other * 0.95)
    }
    // Unmeasured link: a pipeline, and the line says the link is measured at the first load.
    let devices = try freshPair(m4max128, m4max128, layout: layout)
    let unmeasured = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: decodeHeavy, link: .unmeasured)
    checks.require("auto choice 2x M4 Max, link not measured yet: a pipeline, and the line says tensor parallel waits for the link measurement",
        pipelined(unmeasured.chosen) && ClusterPlacementExplanation.deploymentReason(unmeasured)
            .map { $0.hasPrefix("Pipeline") && $0.contains("link") && $0.contains("measured") } == true)
}

/// The recorded M3 Ultra + M5 Ultra profiles with their measured whole-model
/// rates (27B: M3 Ultra 322 prefill / 26.14 ms step, M5 Ultra 1,601 / 17.99)
/// and measured device indices, WITHOUT any shard probe: the prior alone
/// still chooses the pipeline at 1K + 128 (as measured: 4.4 s against 5.6 s).
private func checkRecordedPairWithoutProbes(_ layout: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    var a = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-a.json")))
    var b = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-b.json")))
    a.speedIndex = .init(chip: a.chip, osBuild: a.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1", prefillIndex: 477_000, decodeIndex: 30_900)
    b.speedIndex = .init(chip: b.chip, osBuild: b.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1", prefillIndex: 2_337_768, decodeIndex: 46_409)
    func measured(_ prefill: Double, _ stepMs: Double) -> ClusterDeviceSpeed {
        .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: 1000 / stepMs),
              sustained: nil, explanation: "measured alone, 2026-10-14")
    }
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: measured(322, 26.14)),
                   ClusterPlacementDevice(label: "mac-b", profile: b, speed: measured(1_601, 17.99))]
    let link = ClusterLinkCosts(probe: rdmaProbe(allSumSmallMicroseconds: 85, allSumLargeMicroseconds: 4_000), measuredUTC: "t",
        servedPipelineStepSeconds: 0.008)!
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout,
        policy: policy(prompt: min(1024, layout.maximumPromptTokens), outputs: min(128, layout.maximumOutputTokens)), link: link)
    checks.require("auto choice M3 Ultra + M5 Ultra, measured whole-model rates and indices, no shard probe, 1K + 128: a pipeline (as measured)",
        pipelined(result.chosen) && result.tensorParallel?.devices.allSatisfy({ $0.split.fromHardware == true }) == true)
    checks.require("auto choice M3 Ultra + M5 Ultra: the line says a pipeline and why (tensor parallel predicted slower for this request)",
        ClusterPlacementExplanation.deploymentReason(result).map { $0.hasPrefix("Pipeline") && $0.contains("tensor parallel") } == true)
}

/// The first requests the pair serves in tensor parallel replace the prior:
/// a pair that served slower than the prior predicted gets measured shard
/// rates, and the next plan's split is measured, not from hardware.
private func checkServedReplacesPrior(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let link = productProbe()
    let devices = ClusterHardwarePrior.absolute(try freshPair(
        NewMac(gib: 128, chip: "Apple M4 Max", decodeIndex: 21_100, prefillIndex: 520_000),
        NewMac(gib: 128, chip: "Apple M4 Max", decodeIndex: 21_100, prefillIndex: 520_000), layout: layout), layout: layout, link: link)
    var p = policy(prompt: 128, outputs: 128)
    let predicted = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel,
        prefillSchedule: layout.prefillSchedules.contains(.oneChunkLookahead) ? .oneChunkLookahead : .serial,
        layout: layout, policy: p, link: link)
    let slower = predicted.rested.decodeTokensPerSecond * 0.6
    let samples = (0..<3).map { _ in ClusterServedSample(route: .pair, member: nil, promptTokens: 128, outputTokens: 128,
        firstTokenSeconds: predicted.rested.firstTokenSeconds, decodeTokensPerSecond: slower, finishedAt: 1) }
    let derived = try ClusterServedCalibration.measurements(samples, placement: .init(devices: devices, cuts: [], mode: .tensorParallel,
        schedule: predicted.prefillSchedule, layout: layout, link: link), runtimeBinarySHA256: "served", measuredUTC: "t")
    let shard = derived.first?.rested.tensorShardDecodeTokensPerSecond
    let again = ClusterSpeedEstimator.estimate(devices: devices.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: derived, indices: devices.compactMap(\.profile.speedIndex))
    let next = zip(devices, again).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }
    p.promptTokens = 128
    let replanned = try ClusterPlacementPlanner.plan(devices: next, layout: layout, policy: p, link: link)
    checks.require("auto choice: served tensor-parallel requests replace the prior with measured shard rates (slower served = slower shard)",
        derived.count == 2 && shard != nil
            && replanned.tensorParallel?.devices.allSatisfy({ $0.split.measured && $0.split.fromHardware == nil }) == true
            && (replanned.tensorParallel?.tensorParallel?.prediction(.rested).decodeTokensPerSecond ?? .infinity)
                < predicted.rested.decodeTokensPerSecond * 0.75)
}

private func checkRequestMix(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    func sample(_ prompt: Int, _ output: Int) -> ClusterServedSample {
        .init(route: .pair, member: nil, promptTokens: prompt, outputTokens: output, firstTokenSeconds: 0.5, decodeTokensPerSecond: 40, finishedAt: 1)
    }
    let few = ClusterRequestMix.reference([sample(100, 100), sample(200, 100)], layout: layout)
    let mix = ClusterRequestMix.reference([sample(100, 90), sample(300, 120), sample(200, 500), sample(50_000, 110)], layout: layout)
    checks.require("auto choice: the request mix is the pair's served requests' median prompt and output (none from fewer than three)",
        few == nil && mix?.promptTokens == 250 && mix?.outputTokens == min(115, layout.maximumOutputTokens))
    let clamped = ClusterRequestMix.reference([sample(50_000, 9_000), sample(60_000, 9_000), sample(70_000, 9_000)], layout: layout)
    checks.require("auto choice: the request mix stays within the model's planned request",
        clamped?.promptTokens == layout.maximumPromptTokens && clamped?.outputTokens == layout.maximumOutputTokens)
}

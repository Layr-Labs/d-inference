import CryptoKit
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation


/// Tensor parallel as a planner-chosen mode: the layout facts a family's plan
/// derives from the artifact's own headers, the planner's prediction from each
/// device's decode split (the floor that does not shrink with the weights and
/// the part that does) and the measured reduction over the link, and the rule
/// that it is chosen only where it is predicted faster by the margin, on a
/// keyed reduction, by a runtime that executes it, with served requests
/// correcting it. Constructed Macs; the older-Mac rates are test inputs from a
/// floor-plus-bandwidth model, not claims about those machines. No model, no
/// GPU, no network: not a hardware pass.
func checkTensorParallel(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let nine = try ClusterPlacementLayouts.layout(configuration: inputs.nine.configuration, tensors: inputs.nine.stored)
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    try checkTensorParallelLayouts(nine: nine, big: big, inputs, checks)
    try checkTensorParallelPair(big, golden: golden, checks)
    try checkTensorParallelOlderMacs(big, checks)
    try checkTensorParallelServed(big, checks)
    try checkTensorParallelWeighted(big, checks)
    try checkTensorParallelServedWeighted(big, checks)
    try checkTensorParallelRecord(configuration: inputs.twentySeven.configuration, checks)
    checkShareProbes(checks)
}

/// Share probes measured per share replace the two-point line where present
/// (M3 Ultra, 27B, 2026-10-14: whole 26.14 ms, half 24.66 ms, quarter 16.34 ms).
private func checkShareProbes(_ checks: PlacementChecks) {
    let line = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 322, decodeTokensPerSecond: 1 / 0.02614,
        tensorShardPrefillTokensPerSecond: 598, tensorShardDecodeTokensPerSecond: 1 / 0.02466))
    let probed = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 322, decodeTokensPerSecond: 1 / 0.02614,
        tensorShardPrefillTokensPerSecond: 598, tensorShardDecodeTokensPerSecond: 1 / 0.02466,
        tensorShareRates: [.init(sharePerMille: 250, decodeTokensPerSecond: 1 / 0.01634, prefillTokensPerSecond: 1152)]))
    checks.require("share probes: without them a quarter is extrapolated on the line (floor 23.18 ms + weights x 1/4 = 23.92 ms)",
        abs(line.shareStepSeconds(fraction: 0.25) - 0.023920) < 2e-5 && line.measuredSteps == nil)
    checks.require("share probes: with a quarter probe the quarter steps as measured (16.34 ms), the half as its probe, between them on the measured segment",
        abs(probed.shareStepSeconds(fraction: 0.25) - 0.01634) < 1e-9 && abs(probed.shareStepSeconds(fraction: 0.5) - 0.02466) < 1e-9
            && abs(probed.shareStepSeconds(fraction: 0.375) - 0.0205) < 1e-9 && abs(probed.shareStepSeconds(fraction: 1) - 0.02614) < 1e-9
            && probed.measuredSteps?.map(\.fraction) == [0.25, 0.5, 1])
    checks.require("share probes: below the smallest probe the line is used but never above that probe's own step",
        probed.shareStepSeconds(fraction: 0.1) <= 0.01634)
    let rates = ClusterSpeedRates(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1,
        tensorShareRates: [.init(sharePerMille: 750, decodeTokensPerSecond: 50)])
    checks.require("share probes: a probe is found within 5 per mille of a share and not further",
        rates.shareRate(near: 0.75) != nil && rates.shareRate(near: 0.753) != nil && rates.shareRate(near: 0.76) == nil)
}

// MARK: - The qualification record of a tensor-parallel run

/// `QwenTensorParallelQualification.record`: two passed rank reports over
/// JACCL compared with single-Mac references give a consistent record of
/// mode tensor_parallel_v1, no cut, the registered model and artifact, and
/// the layout the run used; what cannot qualify is refused. Constructed
/// reports (no model run): not a hardware pass.
private func checkTensorParallelRecord(configuration: Data, _ checks: PlacementChecks) throws {
    let sha = SHA256Hex.of(configuration)
    let tokens = Array(100..<132)
    func report(mode: String = "tp", role: String, rank: Int, size: Int, backend: String? = "jaccl", chip: String,
                tokens: [Int], passed: Bool = true, agree: Bool? = true, shares: [Int]? = nil,
                top: ([[Int]], [[Float]])? = nil, socket: Bool = false, reduction: String? = nil) -> Data {
        var object: [String: Any] = ["schema": "darkbloom_cluster_tp_check_report_v1", "mode": mode, "role": role, "rank": rank,
            "size": size, "correctnessOnly": socket, "chip": chip, "modelConfigurationSHA256": sha,
            "modelID": "registered_qwen38_27b", "promptTokens": 1024, "promptTokenIDsSHA256": String(repeating: "c", count: 64),
            "outputCount": tokens.count, "chunkSize": 512, "runs": [["tokenIDs": tokens]], "repeatsIdentical": true,
            "passed": passed]
        if let backend { object["backend"] = backend }
        if let agree { object["ranksAgree"] = agree }
        if let shares { object["shares"] = shares }
        if let reduction { object["reduction"] = reduction }
        if let top { object["topTokenIDs"] = top.0; object["topLogits"] = top.1 }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    let r0 = report(role: "tp2-rank0", rank: 0, size: 2, chip: "Apple M3 Ultra", tokens: tokens)
    let r1 = report(role: "tp2-rank1", rank: 1, size: 2, chip: "Apple M5 Ultra", tokens: tokens)
    let refA = report(mode: "full", role: "full", rank: 0, size: 1, backend: nil, chip: "Apple M3 Ultra", tokens: tokens, agree: nil)
    let refB = report(mode: "full", role: "full", rank: 0, size: 1, backend: nil, chip: "Apple M5 Ultra", tokens: tokens, agree: nil)
    let plan = "qwen_dense_heads_and_channels_v1"
    let record = try QwenTensorParallelQualification.record(rank0: r0, rank1: r1, references: [refA, refB],
        configuration: configuration, planName: plan, partialsDType: "float32", createdUTC: "2026-10-14T07:00:00Z")
    checks.require("tensor parallel record: two passed JACCL ranks against both Macs' references make a consistent, passed record of tensor_parallel_v1 with no cut, the registered 27B and its artifact, and the layout",
        record.isConsistent && record.passed && record.generationMode == "tensor_parallel_v1" && record.cuts.isEmpty
            && record.runtimeModelID == "registered_qwen38_27b" && record.artifactSHA256.count == 64
            && record.ranks.map(\.chip) == ["Apple M3 Ultra", "Apple M5 Ultra"]
            && record.tensorParallelLayout == "plan=\(plan);partials=float32;shares=equal;reduction=native"
            && record.comparisons.map(\.verdict) == ["tokensEqualLogitsDiffer", "tokensEqualLogitsDiffer"]
            && record.producer == "darkbloom-cluster-tp-check record")
    // A near tie at the first difference passes; a real divergence is a failing record (it withholds).
    var other = tokens; other[5] = 7
    let tie = report(mode: "full", role: "full", rank: 0, size: 1, backend: nil, chip: "Apple M3 Ultra", tokens: other, agree: nil,
        top: (Array(repeating: [7, 105], count: 32), Array(repeating: [20.0, 20.0], count: 32)))
    let far = report(mode: "full", role: "full", rank: 0, size: 1, backend: nil, chip: "Apple M3 Ultra", tokens: other, agree: nil,
        top: (Array(repeating: [7, 105], count: 32), Array(repeating: [20.0, 12.0], count: 32)))
    let near = try QwenTensorParallelQualification.record(rank0: r0, rank1: r1, references: [tie], configuration: configuration,
        planName: plan, partialsDType: "float32", createdUTC: "t")
    let diverged = try QwenTensorParallelQualification.record(rank0: r0, rank1: r1, references: [far], configuration: configuration,
        planName: plan, partialsDType: "float32", createdUTC: "t")
    checks.require("tensor parallel record: a 0-ulp tie at the first difference passes; an 8-logit gap is a diverged (withholding) record",
        near.passed && near.comparisons.first?.verdict == "divergedAtNearTie" && near.comparisons.first?.firstDivergenceIndex == 5
            && !diverged.passed && diverged.outcome == .diverged && diverged.isConsistent)
    // Weighted shares are named in the layout.
    let w0 = report(role: "tp2-rank0", rank: 0, size: 2, chip: "Apple M3 Ultra", tokens: tokens, shares: [1, 3])
    let w1 = report(role: "tp2-rank1", rank: 1, size: 2, chip: "Apple M5 Ultra", tokens: tokens, shares: [1, 3])
    let weighted = try QwenTensorParallelQualification.record(rank0: w0, rank1: w1, references: [refA], configuration: configuration,
        planName: plan, partialsDType: "float32", createdUTC: "t")
    checks.require("tensor parallel record: a weighted run's record names its shares (it qualifies 1:3 only)",
        weighted.tensorParallelLayout == "plan=\(plan);partials=float32;shares=1:3;reduction=native")
    let k0 = report(role: "tp2-rank0", rank: 0, size: 2, chip: "Apple M3 Ultra", tokens: tokens, reduction: "sealed-bench")
    let k1 = report(role: "tp2-rank1", rank: 1, size: 2, chip: "Apple M5 Ultra", tokens: tokens, reduction: "sealed-bench")
    let keyed = try QwenTensorParallelQualification.record(rank0: k0, rank1: k1, references: [refA], configuration: configuration,
        planName: plan, partialsDType: "float32", createdUTC: "t")
    checks.require("tensor parallel record: a sealed run's record names its reduction path; a native run's says native",
        keyed.tensorParallelLayout?.hasSuffix(";reduction=sealed-bench") == true)
    checks.refuses("tensor parallel record: refuses ranks that reduced differently", because: "not the same run") {
        _ = try QwenTensorParallelQualification.record(rank0: r0, rank1: k1, references: [refA], configuration: configuration,
            planName: plan, partialsDType: "float32", createdUTC: "t")
    }
    // Refusals.
    let socket0 = report(role: "tp2-rank0", rank: 0, size: 2, backend: "socket", chip: "Apple M3 Ultra", tokens: tokens, socket: true)
    let socket1 = report(role: "tp2-rank1", rank: 1, size: 2, backend: "socket", chip: "Apple M3 Ultra", tokens: tokens, socket: true)
    let failed1 = report(role: "tp2-rank1", rank: 1, size: 2, chip: "Apple M5 Ultra", tokens: tokens, passed: false)
    let otherShares = report(role: "tp2-rank1", rank: 1, size: 2, chip: "Apple M5 Ultra", tokens: tokens, shares: [1, 3])
    for (label, a, b, refs, why) in [
        ("two ranks on one Mac (local socket)", socket0, socket1, [refA], "not across two Macs"),
        ("a rank that did not pass", r0, failed1, [refA], "not one passed"),
        ("ranks of different shares", r0, otherShares, [refA], "not the same run"),
        ("no reference", r0, r1, [Data](), "at least one single-Mac reference"),
        ("a pair report as the reference", r0, r1, [r1], "not a single-Mac full report"),
        ("float32 partials recorded as bfloat16", r0, r1, [refA], "partials dtype"),
    ] as [(String, Data, Data, [Data], String)] {
        checks.refuses("tensor parallel record: refuses \(label)", because: why) {
            _ = try QwenTensorParallelQualification.record(rank0: a, rank1: b, references: refs, configuration: configuration,
                planName: plan, partialsDType: label.hasPrefix("float32 partials") ? "bfloat16" : "float32", createdUTC: "t")
        }
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Unequal Macs: weighted shares

/// The family states which unequal shares its plan accepts; the planner
/// tries each and keeps the fastest. On unequal Macs the faster Mac takes the
/// larger share; equal Macs keep equal shards; a family without options is
/// planned with equal shards only. Constructed Macs (floor-plus-bandwidth
/// test inputs), not a hardware pass.
private func checkTensorParallelWeighted(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let options = big.tensorParallel?.family.shareOptions ?? []
    checks.require("tensor parallel weighted: the 27B layout offers every candidate share its plan accepts (1:3, 1:2, 2:3, 3:2, 2:1, 3:1)",
        options == [[1, 3], [1, 2], [2, 3], [3, 2], [2, 1], [3, 1]])
    let layout = try executing(big)
    // The owner's rule (2026-10-13): sharded deployments only; keep the phase split out of the comparison.
    var sharded = ClusterPlacementPolicy()
    sharded.promptTokens = 1024; sharded.outputTokens = 128
    sharded.admitsShape = { _, _, mode in !mode.isPhaseSplit }
    let slow = modelled(floorMs: 12, bandwidthGBs: 200, weightBytes: weights, prefill: 60)
    let fast = modelled(floorMs: 10, bandwidthGBs: 400, weightBytes: weights, prefill: 150)
    let devices = [try SyntheticMac.idle(32).device("small", speed: slow, chip: "Apple M1 Max"),
                   try SyntheticMac.idle(64).device("large", speed: fast, chip: "Apple M2 Max")]
    let link = linkCosts(reductionMicroseconds: 45)
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: sharded, link: link)
    guard let chosen = result.chosen, chosen.mode == .tensorParallel, let shares = chosen.tensorShares else {
        let seen = ([result.chosen].compactMap { $0 } + result.alternatives).map {
            "\($0.mode.rawValue) \($0.cuts) \($0.tensorShares ?? []) \(String(format: "%.4f", $0.rested.requestSeconds)) tier \($0.tier)" }
        checks.require("tensor parallel weighted: M1 Max 32 GB + M2 Max 64 GB choose tensor parallel with unequal shares (got \(seen.joined(separator: "; ")); assessment \(result.tensorParallel?.reason ?? "-"))", false)
        return
    }
    let largeRank = chosen.ranks.firstIndex { $0.device == "large" } ?? -1
    checks.require("tensor parallel weighted: the faster Mac takes the larger share (\(ClusterPlacementExplanation.shareText(shares)) with the M2 Max as rank \(largeRank))",
        largeRank >= 0 && shares[largeRank] > shares[1 - largeRank])
    // The predicted step is the slower weighted share plus every reduction.
    let fractions = shares.map { Double($0) / Double(shares.reduce(0, +)) }
    let speeds = chosen.ranks.map { rank in rank.device == "large" ? fast : slow }
    let expected = zip(speeds, fractions).map { ClusterDecodeSplit(rates: $0.rested).shareStepSeconds(fraction: $1) }.max()!
        + 129 * (45e-6 + 20_480 / 5e9)
    checks.require("tensor parallel weighted: the predicted step is max over ranks of (floor + weights x share) plus 129 reductions",
        abs(1 / chosen.rested.decodeTokensPerSecond - expected) < 1e-9)
    // Each rank holds about its share of the divided weights plus the replicated embedding.
    let embedding = big.ingress.loadedBytes
    checks.require("tensor parallel weighted: each rank holds about its share of the weights",
        zip(chosen.ranks, fractions).allSatisfy { rank, f in
            let want = Double(weights - embedding) * f + Double(embedding)
            return abs(Double(rank.weightsBytes) - want) / want < 0.03
        })
    // The equal split alone (a family that offers no options) is beaten by the pipeline here.
    let equalOnly = try withoutShareOptions(layout)
    let plain = try ClusterPlacementPlanner.plan(devices: devices, layout: equalOnly, policy: sharded, link: link)
    checks.require("tensor parallel weighted: with equal shards only the same Macs do not choose tensor parallel (the slower Mac's half sets the pace)",
        plain.chosen?.mode.usesTensorParallelDecode == false)
    checks.require("tensor parallel weighted: the weighted choice is faster than the equal-only plan's choice",
        chosen.rested.requestSeconds < (plain.chosen?.rested.requestSeconds ?? 0))
    // Equal Macs keep equal shards.
    let twin = try ClusterPlacementPlanner.plan(devices: [try SyntheticMac.idle(192).device("a", speed: fast, chip: "Apple M2 Ultra"),
                                                          try SyntheticMac.idle(192).device("b", speed: fast, chip: "Apple M2 Ultra")],
                                                layout: layout, policy: sharded, link: link)
    checks.require("tensor parallel weighted: equal Macs that choose tensor parallel keep equal shards (no tensorShares)",
        twin.chosen?.mode == .tensorParallel && twin.chosen?.tensorShares == nil)
    // An explicit evaluation accepts an offered share and refuses another.
    _ = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
        layout: layout, policy: sharded, link: link, tensorShares: [1, 3])
    checks.refuses("tensor parallel weighted: an explicit evaluation refuses shares the family does not offer",
        because: "Tensor-parallel shares must be one the family's plan accepts") {
        _ = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
            layout: layout, policy: sharded, link: link, tensorShares: [1, 7])
    }
    // The plan's words name the split.
    let lines = ClusterPlacementExplanation.candidate(chosen, basis: result.basis, prompt: 1024, outputs: 128)
    checks.require("tensor parallel weighted: the plan says \"tensor parallel, \(ClusterPlacementExplanation.shareText(shares))\"",
        lines.contains { $0.contains("tensor parallel, \(ClusterPlacementExplanation.shareText(shares))") }
            && ClusterPlacementExplanation.shareText([2, 3]) == "40/60" && ClusterPlacementExplanation.shareText([1, 3]) == "25/75")
}

/// Served requests of an unequal split correct the shares they ran at: the
/// setup's cut string names each rank's weight (`0-64@1|0-64@3`), the
/// calibration predicts at those shares (not the equal split's) and records
/// each Mac's step at its own share, so a 1:3 pair served at its prediction
/// re-plans the same and one served slower lowers that split's prediction by
/// what was observed. Constructed Macs (the weighted check's), not hardware.
private func checkTensorParallelServedWeighted(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big)
    var sharded = ClusterPlacementPolicy()
    sharded.promptTokens = 1024; sharded.outputTokens = 128
    sharded.admitsShape = { _, _, mode in !mode.isPhaseSplit }
    sharded.alternatives = 400
    let slow = modelled(floorMs: 12, bandwidthGBs: 200, weightBytes: weights, prefill: 60)
    let fast = modelled(floorMs: 10, bandwidthGBs: 400, weightBytes: weights, prefill: 150)
    let devices = [try SyntheticMac.idle(32).device("small", speed: slow, chip: "Apple M1 Max"),
                   try SyntheticMac.idle(64).device("large", speed: fast, chip: "Apple M2 Max")]
    let link = linkCosts(reductionMicroseconds: 45)
    let first = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: sharded, link: link)
    guard let chosen = first.chosen, chosen.mode == .tensorParallel, let shares = chosen.tensorShares else {
        checks.require("tensor parallel served weighted: the first plan chooses an unequal tensor-parallel split", false)
        return
    }
    let order = chosen.ranks.map(\.device)
    let n = layout.layerCount
    let cut = ClusterServedSpeedRecords.Setup.cut([], layerCount: n, mode: .tensorParallel, ranks: 2, tensorShares: shares)
    checks.require("tensor parallel served weighted: the setup names each rank's weight (\(cut)) and reads back as no cut with those shares; equal shares name none",
        cut == "0-\(n)@\(shares[0])|0-\(n)@\(shares[1])"
            && ClusterServedSpeedRecords.Setup.cuts(cut, layerCount: n, mode: .tensorParallel, ranks: 2) == []
            && ClusterServedSpeedRecords.Setup.tensorShares(cut) == shares
            && ClusterServedSpeedRecords.Setup.cut([], layerCount: n, mode: .tensorParallel, ranks: 2, tensorShares: [2, 2]) == "0-\(n)|0-\(n)"
            && ClusterServedSpeedRecords.Setup.tensorShares("0-\(n)|0-\(n)") == nil
            && ClusterServedSpeedRecords.Setup.cuts("0-16@1|16-\(n)@3", layerCount: n, mode: .pipeline, ranks: 2) == nil
            && ClusterServedSpeedRecords.Setup.cuts("0-\(n)@1|0-\(n)", layerCount: n, mode: .tensorParallel, ranks: 2) == nil)
    func weighted(_ result: ClusterPlacementResult) -> ClusterPlacementCandidate? {
        ([result.chosen].compactMap { $0 } + result.alternatives).first { $0.mode == .tensorParallel && $0.tensorShares == shares
            && $0.ranks.map(\.device) == order }
    }
    let predicted = chosen.rested.decodeTokensPerSecond
    func replan(observedDecode: Double, cut: String) throws -> ClusterPlacementResult {
        let entries = (0..<4).map { index in
            ClusterServedSpeedRecords.Entry(setup: .init(modelID: "m", mode: ClusterGenerationMode.tensorParallel.rawValue, cut: cut, ranks: order),
                sample: ClusterServedSample(route: .pair, member: nil, promptTokens: 1024, outputTokens: 128,
                    firstTokenSeconds: chosen.rested.firstTokenSeconds, decodeTokensPerSecond: observedDecode, finishedAt: Double(1_000 + index)))
        }
        let derived = try ClusterServedCalibration.measurements(entries: entries, devices: devices, layout: layout, link: link,
            measuredUTC: "2026-10-14T06:00:00Z")
        let speeds = ClusterSpeedEstimator.estimate(devices: devices.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: 1024, measurements: derived.measurements)
        let corrected = zip(devices, speeds).map { ClusterPlacementDevice(label: $0.label, profile: $0.profile, speed: $1) }
        return try ClusterPlacementPlanner.plan(devices: corrected, layout: layout, policy: sharded, link: link)
    }
    let confirmed = try replan(observedDecode: predicted, cut: cut)
    checks.require("tensor parallel served weighted: a \(ClusterPlacementExplanation.shareText(shares)) pair served at its predicted decode re-plans the same split at the same decode (got \(confirmed.chosen.map { "\($0.mode.rawValue) \($0.tensorShares ?? []) \($0.rested.decodeTokensPerSecond)" } ?? "-") against \(predicted))",
        confirmed.chosen?.mode == .tensorParallel && confirmed.chosen?.tensorShares == shares
            && abs((confirmed.chosen?.rested.decodeTokensPerSecond ?? 0) - predicted) / predicted < 0.01)
    let slower = try replan(observedDecode: predicted * 0.8, cut: cut)
    let lowered = weighted(slower)?.rested.decodeTokensPerSecond ?? 0
    let seen = ([slower.chosen].compactMap { $0 } + slower.alternatives).map { "\($0.mode.rawValue) \($0.ranks.map(\.device)) \($0.tensorShares ?? []) \(String(format: "%.2f", $0.rested.decodeTokensPerSecond))" }
    checks.require("tensor parallel served weighted: served 20 % slower, that split's next prediction is what was served (\(lowered) against \(predicted * 0.8); candidates \(seen.joined(separator: "; ")))",
        abs(lowered - predicted * 0.8) / (predicted * 0.8) < 0.01)
}

/// The same layout whose family offers no unequal shares.
func withoutShareOptions(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as? [String: Any] ?? [:]
    if var tp = object["tensorParallel"] as? [String: Any], var family = tp["family"] as? [String: Any] {
        family.removeValue(forKey: "shareOptions"); tp["family"] = family; object["tensorParallel"] = tp
    }
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

// MARK: - Layout facts

private func checkTensorParallelLayouts(nine: ClusterModelLayout, big: ClusterModelLayout, _ inputs: RetainedQwenInputs,
                                        _ checks: PlacementChecks) throws {
    for (label, layout, hidden) in [("9B", nine, 4096), ("27B", big, 5120)] {
        guard let tp = layout.tensorParallel else {
            checks.require("tensor parallel \(label): the dense Qwen layout carries the family's tensor-parallel facts", false)
            continue
        }
        checks.require("tensor parallel \(label): plan qwen_dense_heads_and_channels_v1 over two ranks, two reductions a layer and one a step, float32 partials of the residual (\(hidden) x 4 bytes)",
            tp.family.plan == "qwen_dense_heads_and_channels_v1" && tp.family.ranks == [2] && tp.family.reductionsPerLayer == 2
                && tp.family.reductionsPerStep == 1 && tp.family.partialBytesPerToken == hidden * 4 && tp.family.stateDividesByHeads
                && tp.terms == .current)
        checks.require("tensor parallel \(label): \(2 * layout.layerCount + 1) reductions per decode step",
            tp.reductionsPerStep(layerCount: layout.layerCount) == 2 * layout.layerCount + 1)
        let divided = tp.layerDividedBytes.reduce(0, +), replicated = tp.layerReplicatedBytes.reduce(0, +)
        checks.require("tensor parallel \(label): every loaded byte is either divided or replicated, layer by layer, and nearly all layer bytes divide (norms replicate)",
            zip(zip(tp.layerDividedBytes, tp.layerReplicatedBytes), layout.layers).allSatisfy { $0.0 + $0.1 == $1.weights.loadedBytes }
                && Double(divided) / Double(divided + replicated) > 0.999)
        checks.require("tensor parallel \(label): the embedding is replicated and the head divided by vocabulary rows",
            tp.ingressReplicatedBytes == layout.ingress.loadedBytes && tp.ingressDividedBytes == 0
                && tp.egressDividedBytes > 0 && tp.egressDividedBytes + tp.egressReplicatedBytes == layout.egress.loadedBytes)
    }
    // The plan refuses what it does not implement, in its own words; such a
    // layout carries no facts and no tensor-parallel mode is ever predicted.
    let root = try JSONSerialization.jsonObject(with: inputs.twentySeven.configuration) as? [String: Any] ?? [:]
    let text = root["text_config"] as? [String: Any] ?? [:], quantization = root["quantization"] as? [String: Any] ?? [:]
    func refusal(_ change: (inout [String: Any], inout [String: Any]) -> Void) -> String? {
        var t = text, q = quantization
        change(&t, &q)
        do { _ = try QwenTensorParallelPlan(textConfiguration: t, quantization: q, size: 2); return nil } catch { return "\(error)" }
    }
    checks.require("tensor parallel: the registered 27B configuration is covered by the dense plan", refusal { _, _ in } == nil)
    checks.require("tensor parallel: routed experts on a dense model type are refused (the A3B rows are qwen3_5_moe_text)",
        refusal { t, _ in t["num_experts"] = 256 }?.contains("routed experts") == true)
    checks.require("tensor parallel: a non-affine pack (Bonsai's Prism) is not covered yet",
        refusal { _, q in q["mode"] = "prism_hadamard" }?.contains("affine") == true)
    checks.require("tensor parallel: a tied head is not covered yet", refusal { t, _ in t["tie_word_embeddings"] = true }?.contains("tied") == true)
    checks.require("tensor parallel: another model type (MiMo, GPT-OSS, Gemma 4, Nemotron families) is not covered by this plan",
        refusal { t, _ in t["model_type"] = "mimo_v2_flash" }?.contains("qwen3_5_moe_text") == true)
    let synthetic = try syntheticLayout(layers: 8, layerGiB: 1)
    let syntheticPlan = try ClusterPlacementPlanner.plan(devices: [try SyntheticMac.idle(64).device("a"), try SyntheticMac.idle(64).device("b")],
        layout: synthetic)
    checks.require("tensor parallel: a family without a plan has no facts, so no result carries an assessment",
        synthetic.tensorParallel == nil && syntheticPlan.tensorParallel == nil)
    // Facts that contradict the layout are refused.
    if let tp = big.tensorParallel {
        let wrong = ClusterTensorParallelLayout(family: tp.family, layerDividedBytes: tp.layerDividedBytes.map { $0 + 1 },
            layerReplicatedBytes: tp.layerReplicatedBytes, ingressDividedBytes: tp.ingressDividedBytes,
            ingressReplicatedBytes: tp.ingressReplicatedBytes, egressDividedBytes: tp.egressDividedBytes,
            egressReplicatedBytes: tp.egressReplicatedBytes)
        checks.refuses("tensor parallel: facts that do not conserve each layer's bytes are refused", because: "tensor-parallel facts are malformed") {
            _ = try big.with(tensorParallel: wrong)
        }
    }
}

// MARK: - Helpers

/// A layout whose runtime also executes the tensor-parallel modes: the same
/// facts, the modes appended to its list (as a runtime would advertise them).
func executing(_ layout: ClusterModelLayout, _ modes: [ClusterGenerationMode] = [.tensorParallel, .pipelinePrefillTensorDecode]) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as? [String: Any] ?? [:]
    let listed = layout.generationModes + modes.filter { !layout.generationModes.contains($0) }
    object["generationModes"] = ClusterGenerationMode.allCases.filter(listed.contains).map(\.rawValue)
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

/// The same layout as a runtime that executes no tensor-parallel mode lists it.
func notExecuting(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as? [String: Any] ?? [:]
    object["generationModes"] = layout.generationModes.filter { !$0.usesTensorParallelDecode }.map(\.rawValue)
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

/// Rates from a floor-plus-bandwidth model of one Mac on a model of
/// `weightBytes`: a decode step of `floor + weights / bandwidth`, an equal half
/// stepping in `floor + weights / (2 bandwidth)`; prefill at `prefill`, its half
/// at `shardPrefillGain` times that. Test inputs only.
func modelled(floorMs: Double, bandwidthGBs: Double, weightBytes: Int, prefill: Double, shardPrefillGain: Double? = 1.66,
              shard: Bool = true) -> ClusterDeviceSpeed {
    let weights = Double(weightBytes) / (bandwidthGBs * 1e9)
    let whole = floorMs / 1000 + weights, half = floorMs / 1000 + weights / 2
    return .init(source: .measured, absolute: true,
        rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: 1 / whole,
            tensorShardPrefillTokensPerSecond: shard ? shardPrefillGain.map { prefill * $0 } : nil,
            tensorShardDecodeTokensPerSecond: shard ? 1 / half : nil),
        sustained: nil, explanation: "constructed: floor \(floorMs) ms, \(bandwidthGBs) GB/s")
}

func linkCosts(reductionMicroseconds: Double?, keyed: Bool = true) -> ClusterLinkCosts {
    .init(measured: true, perChunkSeconds: 0.002, perDecodeStepSeconds: [:], handoffSecondsPerByte: 1 / 2e9,
          provenance: "constructed for a check",
          reduction: reductionMicroseconds.map { .init(fixedSeconds: $0 / 1e6, secondsPerByte: 1 / 5e9, keyed: keyed,
              provenance: "constructed for a check") })
}

private func policy(prompt: Int = 1024, outputs: Int = 128) -> ClusterPlacementPolicy {
    var p = ClusterPlacementPolicy()
    p.promptTokens = prompt; p.outputTokens = outputs
    return p
}

// MARK: - The pair this was built on

private func checkTensorParallelPair(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    let a = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-a.json")))
    let b = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-b.json")))
    // Whole-model 27B rates in the range measured alone on each (M3 Ultra
    // 35.7 tok/s plain decode, the M5 Ultra about 1.6 times that); no shard probe.
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: measured(prefill: 300, decode: 35.7)),
                   ClusterPlacementDevice(label: "mac-b", profile: b, speed: measured(prefill: 1530, decode: 58))]
    let layout = try executing(big)
    for (label, micro) in [("a keyed exchange (~350 us, the explicit-sync class)", 350.0), ("a native-all-sum-class 45 us", 45.0)] {
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(),
            link: linkCosts(reductionMicroseconds: micro))
        checks.require("tensor parallel M3 Ultra + M5 Ultra, no shard probe, \(label): not chosen (predicted slower), a pipeline stays (sharded by default)",
            result.chosen.map { !$0.mode.usesTensorParallelDecode } == true && result.tensorParallel?.verdict == .predictedSlower
                && result.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true)
    }
    // Even with a shard probe like the M5 Max's (a half stepping in 84.5 % of
    // the whole: 25.1 against 29.7 ms) on both, the faster Mac alone wins.
    func probed(_ prefill: Double, _ decode: Double) -> ClusterDeviceSpeed {
        .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode,
            tensorShardPrefillTokensPerSecond: prefill * 1.66, tensorShardDecodeTokensPerSecond: decode / 0.845),
            sustained: nil, explanation: "constructed")
    }
    let probedDevices = [ClusterPlacementDevice(label: "mac-a", profile: a, speed: probed(300, 35.7)),
                         ClusterPlacementDevice(label: "mac-b", profile: b, speed: probed(1530, 58))]
    let withShard = try ClusterPlacementPlanner.plan(devices: probedDevices, layout: layout, policy: policy(),
        link: linkCosts(reductionMicroseconds: 45))
    checks.require("tensor parallel M3 Ultra + M5 Ultra with an M5-Max-like shard probe: still not chosen; the slower Mac's share sets the pace",
        withShard.tensorParallel?.verdict == .predictedSlower && withShard.chosen?.mode.usesTensorParallelDecode == false)
    if let tp = withShard.tensorParallel?.tensorParallel {
        // The best tensor-parallel candidate may be weighted (the M5 Ultra taking more).
        let step = 1 / tp.rested.decodeTokensPerSecond
        let weightsOf = tp.tensorShares ?? [1, 1]
        let fractions = weightsOf.map { Double($0) / Double(weightsOf.reduce(0, +)) }
        let expected = zip(tp.ranks, fractions).map { rank, f in
            ClusterDecodeSplit(rates: (rank.device == "mac-a" ? probed(300, 35.7) : probed(1530, 58)).rested).shareStepSeconds(fraction: f)
        }.max()! + 129 * (45e-6 + 20_480 / 5e9)
        checks.require("tensor parallel M3 Ultra + M5 Ultra: the predicted step is the slower share plus 129 reductions",
            abs(step - expected) < 1e-9)
        checks.require("tensor parallel M3 Ultra + M5 Ultra: the best tensor-parallel candidate gives the M5 Ultra the larger share",
            tp.tensorShares.map { s in s[tp.ranks.firstIndex { $0.device == "mac-b" }!] > s[tp.ranks.firstIndex { $0.device == "mac-a" }!] } == true)
        // Each rank holds its share of every layer and the replicated embedding.
        let whole = big.wholeModelLoadedBytes, embedding = big.ingress.loadedBytes
        checks.require("tensor parallel M3 Ultra + M5 Ultra: each rank holds about its share of the weights plus the replicated embedding",
            zip(tp.ranks, fractions).allSatisfy { rank, f in
                let expected = Double(whole - embedding) * f + Double(embedding)
                return abs(Double(rank.weightsBytes) - expected) / expected < 0.03 && rank.firstLayer == 0 && rank.endLayer == 64
            } && tp.cuts.isEmpty)
    } else {
        checks.require("tensor parallel M3 Ultra + M5 Ultra: a tensor-parallel candidate was evaluated", false)
    }
    // The explanation says so in words.
    let lines = ClusterPlacementExplanation.describe(withShard, devices: probedDevices, layout: layout, link: linkCosts(reductionMicroseconds: 45))
    checks.require("tensor parallel: the plan's words carry a Tensor parallel section with the verdict and each Mac's floor",
        lines.contains("Tensor parallel") && lines.contains { $0.contains("predictedSlower:") }
            && lines.contains { $0.contains("floor") && $0.contains("a half steps in") })
}

// MARK: - Older and equal Macs, where decode is bandwidth-bound

private func checkTensorParallelOlderMacs(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big)
    struct Pair { let name: String; let a: (gib: Double, chip: String, floor: Double, bw: Double, prefill: Double)
        let b: (gib: Double, chip: String, floor: Double, bw: Double, prefill: Double) }
    let pairs = [
        Pair(name: "2x M1 Max 64 GB", a: (64, "Apple M1 Max", 25, 400, 120), b: (64, "Apple M1 Max", 25, 400, 120)),
        Pair(name: "2x M2 Ultra 192 GB", a: (192, "Apple M2 Ultra", 20, 800, 260), b: (192, "Apple M2 Ultra", 20, 800, 260)),
        Pair(name: "M1 Max 64 GB + M2 Max 96 GB", a: (64, "Apple M1 Max", 25, 400, 120), b: (96, "Apple M2 Max", 22, 400, 150)),
    ]
    for pair in pairs {
        let devices = [try SyntheticMac.idle(pair.a.gib).device("a", speed: modelled(floorMs: pair.a.floor, bandwidthGBs: pair.a.bw,
                           weightBytes: weights, prefill: pair.a.prefill), chip: pair.a.chip),
                       try SyntheticMac.idle(pair.b.gib).device("b", speed: modelled(floorMs: pair.b.floor, bandwidthGBs: pair.b.bw,
                           weightBytes: weights, prefill: pair.b.prefill), chip: pair.b.chip)]
        // A keyed reduction of 45 us (what a reduction sealed on the GPU
        // could reach; the native all-sum's measured class): tensor parallel wins.
        let fast = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(),
            link: linkCosts(reductionMicroseconds: 45))
        let chosenTime = fast.chosen?.rested.requestSeconds ?? 0
        let bestAlone = fast.alone.map(\.rested.requestSeconds).min() ?? 0
        checks.require("tensor parallel \(pair.name), keyed reduction 45 us: a tensor-parallel mode is chosen, at least 5 % faster than every other mode and than either Mac alone",
            fast.chosen?.mode.usesTensorParallelDecode == true && fast.tensorParallel?.verdict == .chosen
                && (fast.tensorParallel?.bestOtherSeconds).map { chosenTime < $0 * 0.95 } == true && chosenTime < bestAlone * 0.95)
        // The keyed exchange as Swift reaches it today (eval, seal, send,
        // open per reduction: the explicit-sync class, about 350 us): it loses.
        let slow = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(),
            link: linkCosts(reductionMicroseconds: 350))
        checks.require("tensor parallel \(pair.name), keyed reduction 350 us: not chosen (predicted slower)",
            slow.chosen?.mode.usesTensorParallelDecode == false && slow.tensorParallel?.verdict == .predictedSlower)
        // Only a keyed measurement chooses: the same 45 us measured as a native all-sum never does.
        let unkeyed = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(),
            link: linkCosts(reductionMicroseconds: 45, keyed: false))
        checks.require("tensor parallel \(pair.name): a reduction measured unkeyed (native all-sum, plaintext on the cable) is reported and never chosen on",
            unkeyed.chosen?.mode.usesTensorParallelDecode == false && unkeyed.tensorParallel?.verdict == .reductionNotMeasured
                && unkeyed.tensorParallel?.tensorParallel != nil)
        // No reduction measured at all: nothing to predict.
        let none = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(), link: linkCosts(reductionMicroseconds: nil))
        checks.require("tensor parallel \(pair.name): with no reduction measured nothing is predicted and nothing is chosen",
            none.chosen?.mode.usesTensorParallelDecode == false && none.tensorParallel?.verdict == .reductionNotMeasured
                && none.tensorParallel?.tensorParallel == nil)
        // The runtime as built lists no tensor-parallel mode: predicted faster, not chosen, and said so.
        let today = try ClusterPlacementPlanner.plan(devices: devices, layout: try notExecuting(big), policy: policy(), link: linkCosts(reductionMicroseconds: 45))
        checks.require("tensor parallel \(pair.name): with a runtime that lists no tensor-parallel mode the verdict is notExecutedByRuntime, never chosen",
            today.chosen?.mode.usesTensorParallelDecode == false && today.tensorParallel?.verdict == .notExecutedByRuntime)
        // Records that admit no tensor-parallel shape keep it out.
        var gated = policy()
        gated.admitsShape = { _, _, mode in !mode.usesTensorParallelDecode }
        let unqualified = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: gated, link: linkCosts(reductionMicroseconds: 45))
        checks.require("tensor parallel \(pair.name): when no passed record admits the shape the verdict is notQualified",
            unqualified.chosen?.mode.usesTensorParallelDecode == false && unqualified.tensorParallel?.verdict == .notQualified)
        // Without a shard probe nothing says a half steps faster: never chosen.
        let unprobed = [try SyntheticMac.idle(pair.a.gib).device("a", speed: modelled(floorMs: pair.a.floor, bandwidthGBs: pair.a.bw,
                            weightBytes: weights, prefill: pair.a.prefill, shard: false), chip: pair.a.chip),
                        try SyntheticMac.idle(pair.b.gib).device("b", speed: modelled(floorMs: pair.b.floor, bandwidthGBs: pair.b.bw,
                            weightBytes: weights, prefill: pair.b.prefill, shard: false), chip: pair.b.chip)]
        let blind = try ClusterPlacementPlanner.plan(devices: unprobed, layout: layout, policy: policy(), link: linkCosts(reductionMicroseconds: 45))
        checks.require("tensor parallel \(pair.name): without a shard probe a half is assumed no faster, so it is never chosen",
            blind.chosen?.mode.usesTensorParallelDecode == false && blind.tensorParallel?.verdict == .predictedSlower)
    }
    // Where it would win by less than the margin it is not chosen: equal Macs
    // whose floor is most of the step (a half saves little).
    let floorBound = [try SyntheticMac.idle(64).device("a", speed: modelled(floorMs: 40, bandwidthGBs: 1600, weightBytes: weights, prefill: 300),
                          chip: "Apple M2 Max"),
                      try SyntheticMac.idle(64).device("b", speed: modelled(floorMs: 40, bandwidthGBs: 1600, weightBytes: weights, prefill: 300),
                          chip: "Apple M2 Max")]
    let close = try ClusterPlacementPlanner.plan(devices: floorBound, layout: layout, policy: policy(), link: linkCosts(reductionMicroseconds: 30))
    checks.require("tensor parallel: floor-bound equal Macs (a half saves under 5 ms of 49, the reductions cost 4) are not chosen within the margin",
        close.chosen?.mode.usesTensorParallelDecode == false && close.tensorParallel?.verdict == .predictedSlower)
    // Two Macs that cannot hold the model alone: tensor parallel competes with the pipeline.
    let small = [try SyntheticMac.idle(16).device("a", speed: modelled(floorMs: 25, bandwidthGBs: 200, weightBytes: weights, prefill: 60),
                     chip: "Apple M1 Pro"),
                 try SyntheticMac.idle(16).device("b", speed: modelled(floorMs: 25, bandwidthGBs: 200, weightBytes: weights, prefill: 60),
                     chip: "Apple M1 Pro")]
    let tight = try ClusterPlacementPlanner.plan(devices: small, layout: layout, policy: policy(), link: linkCosts(reductionMicroseconds: 45))
    checks.require("tensor parallel: two 16 GB Macs that cannot hold the 27B alone (nor a phase split) choose tensor parallel over the pipeline when it fits and is faster",
        tight.alone.allSatisfy { !$0.fit.possible || $0.fit.tier > 0 }
            && (tight.chosen.map { $0.mode.usesTensorParallelDecode || $0.tier > 0 } ?? true))
}

// MARK: - Served requests correct the prediction

private func checkTensorParallelServed(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big)
    let speed = modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260)
    let devices = [try SyntheticMac.idle(192).device("a", speed: speed, chip: "Apple M2 Ultra"),
                   try SyntheticMac.idle(192).device("b", speed: speed, chip: "Apple M2 Ultra")]
    let link = linkCosts(reductionMicroseconds: 45)
    let first = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy(), link: link)
    guard let chosen = first.chosen, chosen.mode.usesTensorParallelDecode else {
        checks.require("tensor parallel served: the first plan chooses tensor parallel (2x M2 Ultra, keyed 45 us)", false)
        return
    }
    let predicted = chosen.rested.decodeTokensPerSecond
    func replan(observedDecode: Double) throws -> ClusterPlacementResult {
        let samples = (0..<4).map { index in
            ClusterServedSample(route: .pair, member: nil, promptTokens: 1024, outputTokens: 128,
                firstTokenSeconds: chosen.rested.firstTokenSeconds, decodeTokensPerSecond: observedDecode, finishedAt: Double(1_000 + index))
        }
        let measurements = try ClusterServedCalibration.measurements(samples,
            placement: .init(devices: devices, cuts: chosen.cuts, mode: chosen.mode, schedule: chosen.prefillSchedule,
                layout: layout, link: link), runtimeBinarySHA256: String(repeating: "f", count: 64), measuredUTC: "2026-10-14T06:00:00Z")
        let speeds = ClusterSpeedEstimator.estimate(devices: devices.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: 1024, measurements: measurements)
        let corrected = zip(devices, speeds).map { ClusterPlacementDevice(label: $0.label, profile: $0.profile, speed: $1) }
        return try ClusterPlacementPlanner.plan(devices: corrected, layout: layout, policy: policy(), link: link)
    }
    let confirmed = try replan(observedDecode: predicted)
    checks.require("tensor parallel served: requests served at the predicted rate keep tensor parallel chosen, at the same predicted decode",
        confirmed.chosen?.mode.usesTensorParallelDecode == true
            && abs((confirmed.chosen?.rested.decodeTokensPerSecond ?? 0) - predicted) / predicted < 0.01)
    let slower = try replan(observedDecode: predicted * 0.8)
    checks.require("tensor parallel served: requests served 20 % slower than predicted lower the shard rates and the next plan stops choosing tensor parallel",
        slower.chosen?.mode.usesTensorParallelDecode == false && slower.tensorParallel?.verdict == .predictedSlower)
    // A setup's cut string for tensor parallel names every rank 0-<layers> and round-trips to no cut.
    let cut = ClusterServedSpeedRecords.Setup.cut([], layerCount: 64, mode: .tensorParallel, ranks: 2)
    checks.require("tensor parallel served: the setup is named 0-64|0-64 and reads back as no cut; a pipeline cut string still reads as before",
        cut == "0-64|0-64" && ClusterServedSpeedRecords.Setup.cuts(cut, layerCount: 64, mode: .tensorParallel, ranks: 2) == []
            && ClusterServedSpeedRecords.Setup.cuts("0-16|16-64", layerCount: 64, mode: .pipelinePrefillTensorDecode, ranks: 2) == [16]
            && ClusterServedSpeedRecords.Setup.cuts("0-16|16-64", layerCount: 64, mode: .tensorParallel, ranks: 2) == nil)
    // A shard rate is the chip's own: never transferred to another device by a ratio.
    let other = ClusterSpeedEstimator.estimate(devices: [.init(chip: "Apple M2 Ultra", osBuild: "SYNTH"), .init(chip: "Apple M1 Max", osBuild: "SYNTH")],
        artifactSHA256: layout.artifactSHA256, measurements: [try .init(key: .init(artifactSHA256: layout.artifactSHA256, chip: "Apple M2 Ultra",
            osBuild: "SYNTH", runtimeBinarySHA256: "x", probe: "p"), promptTokens: 1024, chunkTokens: 512, probedLayers: 64, layerCount: 64,
            rested: speed.rested, sustained: nil, measuredUTC: "2026-10-14T06:00:00Z", provenance: "constructed")],
        indices: [.init(chip: "Apple M2 Ultra", osBuild: "SYNTH", benchmark: "b", prefillIndex: 2, decodeIndex: 2),
                  .init(chip: "Apple M1 Max", osBuild: "SYNTH", benchmark: "b", prefillIndex: 1, decodeIndex: 1)])
    checks.require("tensor parallel: a shard rate is never transferred to another chip (the other Mac's estimate has none)",
        other[0].rested.tensorShardDecodeTokensPerSecond != nil && other[1].rested.tensorShardDecodeTokensPerSecond == nil)
    let record = try ClusterSpeedMeasurement(key: .init(artifactSHA256: "a", chip: "c", osBuild: "o", runtimeBinarySHA256: "r", probe: "p"),
        promptTokens: 1, chunkTokens: 1, probedLayers: 1, layerCount: 1, rested: speed.rested, sustained: nil, measuredUTC: "t", provenance: "p")
    let plainRecord = try ClusterSpeedMeasurement(key: record.key, promptTokens: 1, chunkTokens: 1, probedLayers: 1, layerCount: 1,
        rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1), sustained: nil, measuredUTC: "t", provenance: "p")
    checks.require("tensor parallel: a speed record with shard rates is schema v2; without them v1 as before",
        record.schema == ClusterSpeedMeasurement.schemaNameV2 && plainRecord.schema == ClusterSpeedMeasurement.schemaName)
}

import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The registered layout with the model's speculative head added as the real
/// artifact stores it: `count` tensors under `mtp.` summing to `bytes`. The
/// retained header metadata keeps only what a stage loads, so the head is
/// added back here at the size the artifact's own headers give it.
func layoutWithHead(_ profile: RetainedQwenInputs.Profile, bytes: Int, count: Int) throws -> ClusterModelLayout {
    let piece = bytes / count
    let head = (0..<count).map { index in
        ClusterPlacementStoredTensor(name: "mtp.check.t\(index)", byteCount: index == count - 1 ? bytes - piece * (count - 1) : piece)
    }
    return try ClusterPlacementLayouts.layout(configuration: profile.configuration, tensors: profile.stored + head)
}

/// The same layout as a build before the row's credit wrote it.
func withoutCredit(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
    object["speculativeDecodeFactor"] = nil
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
}

/// MTP on by default on planner-built setups (PERF-BACKLOG item 2): the
/// model's row credits its head, the planner prefers it on a decoding Mac
/// where it is credited and plain decode where it is not, and the decoding
/// rank is charged the head's memory. Constructed Macs named as the pair's
/// chips report them; no model, no GPU.
func checkSpeculativeCredit(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    // The heads' sizes as the two artifacts' safetensors headers give them.
    let nine = try layoutWithHead(inputs.nine, bytes: 136_881_152, count: 31)
    let big = try layoutWithHead(inputs.twentySeven, bytes: 238_930_944, count: 31)
    let bare = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    checks.require("(a) the rows credit the head with the smallest pair speed-up measured: 9B 1.44, 27B 1.56",
        nine.speculativeDecodeFactor == 1.44 && big.speculativeDecodeFactor == 1.56 && bare.speculativeDecodeFactor == 1.56)
    checks.require("the head is the excluded part under mtp., and only what the headers name",
        big.speculativeHead?.storedBytes == 238_930_944 && big.speculativeHead?.tensorCount == 31
            && nine.speculativeHead?.loadedBytes == 136_881_152 && bare.speculativeHead == nil
            && big.excluded.storedBytes == 238_930_944 && big.wholeModelLoadedBytes == bare.wholeModelLoadedBytes)
    checks.require("a layout with the head and its credit survives its own encoding", try ClusterModelLayout.decode(big.encoded()) == big)
    // A layout written before these fields loads, with neither.
    var old = try JSONSerialization.jsonObject(with: big.encoded()) as! [String: Any]
    old["speculativeHead"] = nil; old["speculativeDecodeFactor"] = nil
    let oldLayout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: old))
    checks.require("a layout written before the head was derived loads, crediting nothing",
        oldLayout.speculativeHead == nil && oldLayout.speculativeDecodeFactor == nil && oldLayout.layers == big.layers)
    checks.refuses("a credit below 1 is refused", because: "speculative head is malformed") {
        var object = try JSONSerialization.jsonObject(with: big.encoded()) as! [String: Any]
        object["speculativeDecodeFactor"] = 0.9
        _ = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    }
    checks.refuses("a credit on a layout without the speculative phase split is refused", because: "speculative head is malformed") {
        var object = try JSONSerialization.jsonObject(with: big.encoded()) as! [String: Any]
        object["generationModes"] = [ClusterGenerationMode.pipeline.rawValue]
        _ = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    }

    // The chip generation, read from the name's form only.
    checks.require("the generation is read from the chip name's form, and nothing else",
        ClusterSpeculativeCredit.generation(chip: "Apple M5 Max") == 5 && ClusterSpeculativeCredit.generation(chip: "Apple M3 Ultra") == 3
            && ClusterSpeculativeCredit.generation(chip: "Apple M5 Ultra") == 5 && ClusterSpeculativeCredit.generation(chip: "Apple M12") == 12
            && ClusterSpeculativeCredit.generation(chip: "Synthetic") == nil && ClusterSpeculativeCredit.generation(chip: "Apple Mx Max") == nil
            && ClusterSpeculativeCredit.generation(chip: "Apple M") == nil && ClusterSpeculativeCredit.generation(chip: "Intel M5") == nil)

    // This pair's shape with nothing measured: the M3 Ultra (256 GiB) and an M5 (128 GiB).
    let m3 = try SyntheticMac.idle(256).device("mac-a", chip: "Apple M3 Ultra")
    let m5 = try SyntheticMac.idle(128).device("mac-b", chip: "Apple M5 Max")
    for (name, layout, cut) in [("9B", nine, 16), ("27B", big, 32)] {
        // A layout from a plan tool before this change (no credit): every mode ties on time, and the head on
        // the M5 is preferred ahead of headroom, where the old order chose the pipeline on headroom.
        let uncredited = try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: try withoutCredit(layout), policy: handOffPolicy())
        let pipelineTime = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [cut], mode: .pipeline,
            prefillSchedule: .oneChunkLookahead, layout: layout).rested.requestSeconds
        checks.require("\(name), M3 Ultra + M5, a layout with no credit: phase_split_mtp_v1 at cut \(cut) on equal time, the M5 decoding",
            uncredited.chosen?.mode == .phaseSplitMTP && uncredited.chosen?.cut == cut && uncredited.chosen?.ranks.last?.device == "mac-b"
                && uncredited.chosen?.rested.requestSeconds == pipelineTime)
        let quiet = ClusterPlacementExplanation.describe(uncredited, devices: [m3, m5], layout: try withoutCredit(layout)).joined(separator: "\n")
        checks.require("\(name), a layout with no credit: the plan says the head runs as on one Mac and no speed-up is counted",
            quiet.contains("names no measured speed-up, so the times above are those of plain decode"))
        let credited = ClusterPlacementExplanation.describe(try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: layout, policy: handOffPolicy()),
            devices: [m3, m5], layout: layout).joined(separator: "\n")
        checks.require("\(name): the plan names the credit and why the M5 has it",
            credited.contains("credited with \(String(format: "%.2f", layout.speculativeDecodeFactor ?? 0))x its plain decode")
                && credited.contains("mac-b's GPU is of the first generation with matrix accelerators (Apple M5)"))
        for leader in [nil, "mac-a"] {
            var policy = handOffPolicy(); policy.leader = leader
            let result = try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: layout, policy: policy)
            checks.require("\(name), M3 Ultra + M5, nothing measured\(leader.map { ", led by \($0)" } ?? ""): phase_split_mtp_v1 at cut \(cut), the M3 Ultra first and the M5 decoding",
                result.chosen?.mode == .phaseSplitMTP && result.chosen?.cut == cut
                    && result.chosen?.ranks.map(\.device) == ["mac-a", "mac-b"] && result.chosen?.tier == 0)
            // (e) the planning request is unchanged: the layout's largest.
            checks.require("\(name): the planned request is still \(layout.maximumPromptTokens) prompt and \(layout.maximumOutputTokens) output tokens",
                result.promptTokens == layout.maximumPromptTokens && result.outputTokens == layout.maximumOutputTokens
                    && result.outputTokens == 128)
        }
        // The credit shortens the request by the head's decode: 127 steps at 1/factor of the plain step.
        let plain = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [cut], mode: .phaseSplit, prefillSchedule: .oneChunkLookahead, layout: layout)
        let headed = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [cut], mode: .phaseSplitMTP, prefillSchedule: .oneChunkLookahead, layout: layout)
        let factor = layout.speculativeDecodeFactor ?? 1
        checks.require("\(name): the head's decode is the plain decode times \(factor), and the first token is unchanged",
            abs(headed.rested.decodeTokensPerSecond / plain.rested.decodeTokensPerSecond - factor) < 1e-9
                && headed.rested.firstTokenSeconds == plain.rested.firstTokenSeconds
                && abs((plain.rested.requestSeconds - headed.rested.requestSeconds) - 127 * (1 - 1 / factor) / plain.rested.decodeTokensPerSecond) < 1e-6)
        // (f) the decoding rank holds the head as well.
        let page = m5.profile.memory.pageSizeBytes, head = layout.speculativeHead!
        checks.require("\(name): the decoding rank of the speculative split holds the head's \(head.loadedBytes) bytes on top of the plain split's weights",
            headed.ranks[1].weightsBytes == plain.ranks[1].weightsBytes + head.loadedBytes + head.tensorCount * page
                && headed.ranks[1].needBytes > plain.ranks[1].needBytes && headed.ranks[0].weightsBytes == plain.ranks[0].weightsBytes)
        checks.require("\(name): the holdings a status view computes include the head on the decoding rank",
            ClusterPlacementHoldings.weightsBytes(layout: layout, boundaries: [cut], mode: .phaseSplitMTP, pageSizeBytes: page)
                == headed.ranks.map(\.weightsBytes))
    }
    // The 27B's assumed-equal relative time: 4479 for every mode before, the head now faster.
    do {
        let pipeline = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [32], mode: .pipeline, prefillSchedule: .oneChunkLookahead, layout: big)
        let headed = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [32], mode: .phaseSplitMTP, prefillSchedule: .oneChunkLookahead, layout: big)
        checks.require("27B, assumed equal: the pipeline's relative time is 4479 and the head's 4352 + 127/1.56",
            abs(pipeline.rested.requestSeconds - 4479) < 1e-6 && abs(headed.rested.requestSeconds - (4352 + 127 / 1.56)) < 1e-6)
    }

    // (d) the decoding Mac. The mirrored 27B (the M5 leading, the M3 Ultra decoding) is not credited: the
    // plain phase split or the pipeline is chosen, never the head on the M3 Ultra.
    do {
        var policy = handOffPolicy(); policy.leader = "mac-b"
        let mirrored = try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: big, policy: policy)
        checks.require("27B led by the M5 (the M3 Ultra decoding): no head on the M3 Ultra",
            mirrored.chosen.map { !$0.mode.usesSpeculativeHead && $0.ranks.map(\.device) == ["mac-b", "mac-a"] } ?? false)
        let ranked = [mirrored.chosen!] + mirrored.alternatives
        let plainSplit = ranked.firstIndex { $0.mode == .phaseSplit && $0.cut == mirrored.chosen!.cut }
        let headSplit = ranked.firstIndex { $0.mode == .phaseSplitMTP && $0.cut == mirrored.chosen!.cut }
        checks.require("27B mirrored: at one cut the plain phase split ranks before the same split with the head on the M3 Ultra",
            plainSplit != nil && (headSplit == nil || plainSplit! < headSplit!))
        let text = ClusterPlacementExplanation.describe(try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: big,
            policy: { var p = handOffPolicy(); p.leader = "mac-b"; p.modes = [.phaseSplit, .phaseSplitMTP]; return p }()),
            devices: [m3, m5], layout: big).joined(separator: "\n")
        checks.require("27B mirrored, phase splits only: the plan says the head is not credited on the M3 Ultra and why",
            text.contains("speculative (MTP) head is not credited on mac-a") && text.contains("generation before Apple M5")
                && text.contains("plain greedy decode is the reference itself"))
    }
    // Two M3 Ultras: nothing credits the head; two M5s: the head is credited whichever decodes.
    do {
        let a = try SyntheticMac.idle(256).device("a", chip: "Apple M3 Ultra"), b = try SyntheticMac.idle(256).device("b", chip: "Apple M3 Ultra")
        let result = try checkRule("two M3 Ultras, 27B with its head", [a, b], big, checks, policy: handOffPolicy())
        checks.require("two M3 Ultras: the head is never chosen", result.chosen.map { !$0.mode.usesSpeculativeHead } ?? false)
        let c = try SyntheticMac.idle(128).device("c", chip: "Apple M5 Max"), d = try SyntheticMac.idle(256).device("d", chip: "Apple M5 Ultra")
        let fives = try checkRule("an M5 Max and an M5 Ultra, 27B with its head", [c, d], big, checks, policy: handOffPolicy())
        checks.require("two M5s: the head is chosen", fives.chosen?.mode == .phaseSplitMTP)
        _ = try checkRule("M3 Ultra + M5, 9B with its head", [m3, m5], nine, checks, policy: handOffPolicy())
        _ = try checkRule("M3 Ultra + M5, 27B with its head", [m3, m5], big, checks, policy: handOffPolicy())
    }
    // (c) ahead of headroom: the M5's headroom is the smallest under any phase split, and the head still wins.
    do {
        let pipeline = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [32], mode: .pipeline, prefillSchedule: .oneChunkLookahead, layout: big)
        let headed = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [32], mode: .phaseSplitMTP, prefillSchedule: .oneChunkLookahead, layout: big)
        checks.require("the head's split keeps less headroom than the pipeline and is chosen anyway (the rule is ahead of headroom)",
            headed.smallestHeadroomShare < pipeline.smallestHeadroomShare && headed.smallestHeadroomShare >= 0.10)
        // With no credit at all, equal times: the plain modes come first, the lower cut and the labels decide among them.
        var policy = handOffPolicy(); policy.modes = [.pipeline, .phaseSplitMTP]
        let unknownChips = [try SyntheticMac.idle(256).device("a"), try SyntheticMac.idle(128).device("b")]
        let uncredited = try ClusterPlacementPlanner.plan(devices: unknownChips, layout: big, policy: policy)
        checks.require("chips of no known generation: plain decode is preferred and the pipeline is kept", uncredited.chosen?.mode == .pipeline)
    }
    // A tight decoding Mac: live headroom does not override the head (owner, 2026-10-18); the gate decides at load.
    do {
        let need = try ClusterPlacementPlanner.evaluate(devices: [m3, m5], cuts: [32], mode: .phaseSplitMTP,
            prefillSchedule: .oneChunkLookahead, layout: big).ranks[1].needBytes
        let tight = SyntheticMac(physicalGiB: 128, freeGiB: Double(need) * 1.05 / Double(gib), inactiveCacheGiB: 0, wiredGiB: 6)
        let result = try ClusterPlacementPlanner.plan(devices: [m3, try tight.device("mac-b", chip: "Apple M5 Max")], layout: big, policy: handOffPolicy())
        checks.require("an M5 with under a tenth in reserve for the whole model: the head's split is chosen as for the idle M5, its small reserve reported",
            result.chosen?.mode == .phaseSplitMTP && result.chosen?.cut == 32 && result.chosen?.ranks.map(\.device) == ["mac-a", "mac-b"]
                && (result.chosen?.smallestHeadroomShare ?? 1) < 0.10)
    }
    // One Mac alone: the M5 alone runs its head as the product does; the M3 Ultra alone decodes plainly.
    do {
        let result = try ClusterPlacementPlanner.plan(devices: [m3, m5], layout: big, policy: handOffPolicy())
        let five = result.alone.first { $0.device == "mac-b" }!, three = result.alone.first { $0.device == "mac-a" }!
        checks.require("alone: the M5 is predicted with its head and the M3 Ultra without, and the M5 holds the head",
            abs(five.rested.decodeTokensPerSecond - 1.56) < 1e-9 && three.rested.decodeTokensPerSecond == 1
                && five.needBytes > three.needBytes)
    }

    // (b) speed records: a measured rate with the head decides in either direction.
    let fast = ClusterDeviceSpeed(source: .measured, absolute: true,
        rested: .init(prefillTokensPerSecond: 728, decodeTokensPerSecond: 27.8, speculativeDecodeTokensPerSecond: 46.3),
        sustained: .init(prefillTokensPerSecond: 600, decodeTokensPerSecond: 26.7, speculativeDecodeTokensPerSecond: 22.5),
        explanation: "constructed from the M5 Max's 27B runs at 5,120 (heat-soaked sustained figures)")
    let slow = ClusterDeviceSpeed(source: .measured, absolute: true,
        rested: .init(prefillTokensPerSecond: 315, decodeTokensPerSecond: 30.6), sustained: nil,
        explanation: "constructed from the M3 Ultra's 27B runs at 5,120")
    do {
        let pair = [try SyntheticMac.idle(256).device("mac-a", speed: slow, chip: "Apple M3 Ultra"),
                    try SyntheticMac.idle(128).device("mac-b", speed: fast, chip: "Apple M5 Max")]
        let rested = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: handOffPolicy())
        checks.require("measured: rested, the M5's measured 46.3 with the head beats every plain mode; the head is chosen with the M5 decoding",
            rested.chosen?.mode == .phaseSplitMTP && rested.chosen?.ranks.last?.device == "mac-b"
                && abs((rested.chosen?.rested.decodeTokensPerSecond ?? 0) - 46.3) < 1e-9)
        var sustainedPolicy = handOffPolicy(); sustainedPolicy.regime = .sustained
        let sustained = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: sustainedPolicy)
        checks.require("measured: sustained, the heat-soaked M5's 22.5 with the head loses to its 26.7 without; the head is not chosen",
            sustained.chosen.map { !$0.mode.usesSpeculativeHead } ?? false && rested.chosenForOtherRegime?.mode.usesSpeculativeHead == false)
        let text = ClusterPlacementExplanation.describe(rested, devices: pair, layout: big).joined(separator: "\n")
        checks.require("measured: the plan names the measured rate with the head",
            text.contains("mac-b measured 46.3 tok/s with it against 27.8 without") && text.contains("(46.3 with the model's speculative head) rested"))
        // An M3 Ultra that measured its head faster is credited too: a measurement outranks the generation rule.
        let m3Fast = ClusterDeviceSpeed(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 315, decodeTokensPerSecond: 30.6, speculativeDecodeTokensPerSecond: 40), sustained: nil, explanation: "constructed")
        let m5Slow = ClusterDeviceSpeed(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 728, decodeTokensPerSecond: 27.8, speculativeDecodeTokensPerSecond: 25), sustained: nil, explanation: "constructed")
        let swapped = [try SyntheticMac.idle(256).device("mac-a", speed: m3Fast, chip: "Apple M3 Ultra"),
                       try SyntheticMac.idle(128).device("mac-b", speed: m5Slow, chip: "Apple M5 Max")]
        let measuredRule = try ClusterPlacementPlanner.plan(devices: swapped, layout: big, policy: handOffPolicy())
        checks.require("measured: the head goes where it measured faster, whatever the generation",
            measuredRule.chosen?.mode == .phaseSplitMTP && measuredRule.chosen?.ranks.last?.device == "mac-a")
    }
    // Records: v1 unchanged, v2 only with a rate with the head; a v1 record cannot carry one; transfers drop it.
    do {
        let key = ClusterSpeedKey(artifactSHA256: "m", chip: "Apple M5 Max", osBuild: "1", runtimeBinarySHA256: "bin", probe: "p")
        let v1 = try ClusterSpeedMeasurement(key: key, promptTokens: 5120, chunkTokens: 512, probedLayers: 64, layerCount: 64,
            rested: .init(prefillTokensPerSecond: 728, decodeTokensPerSecond: 27.8), sustained: nil,
            measuredUTC: "2026-10-11T00:00:00Z", provenance: "constructed")
        let v2 = try ClusterSpeedMeasurement(key: key, promptTokens: 5120, chunkTokens: 512, probedLayers: 64, layerCount: 64,
            rested: .init(prefillTokensPerSecond: 728, decodeTokensPerSecond: 27.8, speculativeDecodeTokensPerSecond: 46.3), sustained: nil,
            measuredUTC: "2026-10-11T00:00:00Z", provenance: "constructed")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let v1Text = String(decoding: try encoder.encode(v1), as: UTF8.self)
        checks.require("a record without a rate with the head is still written as v1, with no new field",
            v1.schema == ClusterSpeedMeasurement.schemaName && !v1Text.contains("speculative"))
        checks.require("a record with one is v2 and survives its encoding",
            try v2.schema == ClusterSpeedMeasurement.schemaNameV2 && JSONDecoder().decode(ClusterSpeedMeasurement.self, from: encoder.encode(v2)) == v2)
        // A record exactly as v1 producers wrote it before this change.
        let written = #"{"chunkTokens":512,"key":{"artifactSHA256":"m","chip":"Apple M5 Max","osBuild":"1","probe":"p","runtimeBinarySHA256":"bin"},"layerCount":64,"measuredUTC":"2026-10-11T00:00:00Z","probedLayers":64,"promptTokens":5120,"provenance":"constructed","rested":{"decodeTokensPerSecond":27.8,"prefillTokensPerSecond":728},"schema":"darkbloom_cluster_speed_measurement_v1"}"#
        let loaded = try JSONDecoder().decode(ClusterSpeedMeasurement.self, from: Data(written.utf8))
        checks.require("a v1 record written before this change still loads", (try? loaded.validate()) != nil && loaded == v1)
        checks.refuses("a v1 record that carries a rate with the head is refused", because: "Speed measurement is malformed") {
            let forged = written.replacingOccurrences(of: #""decodeTokensPerSecond":27.8,"#, with: #""decodeTokensPerSecond":27.8,"speculativeDecodeTokensPerSecond":46.3,"#)
            try JSONDecoder().decode(ClusterSpeedMeasurement.self, from: Data(forged.utf8)).validate()
        }
        let a = ClusterSpeedEstimator.Subject(chip: "Apple M5 Max", osBuild: "1"), b = ClusterSpeedEstimator.Subject(chip: "Apple M3 Ultra", osBuild: "2")
        let index = [ClusterDeviceIndex(chip: "Apple M5 Max", osBuild: "1", benchmark: "x", prefillIndex: 2, decodeIndex: 1),
                     ClusterDeviceIndex(chip: "Apple M3 Ultra", osBuild: "2", benchmark: "x", prefillIndex: 1, decodeIndex: 1)]
        let estimated = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m", measurements: [v2], indices: index)
        checks.require("the measuring device keeps its rate with the head; a device scaled from it gets none",
            estimated[0].rested.speculativeDecodeTokensPerSecond == 46.3 && estimated[1].source == .transferredByDeviceIndex
                && estimated[1].rested.speculativeDecodeTokensPerSecond == nil)
        let assumed = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m", measurements: [v2])
        checks.require("a device assumed equal to the measuring one gets no rate with the head",
            assumed[1].source == .assumedEqual && assumed[1].rested.speculativeDecodeTokensPerSecond == nil)
    }
}

/// The speculative head rides on the phase split, kept but off by default
/// (sharded deployments only, 2026-10-13): these checks hold it to its
/// behaviour under the explicit hand-off opt-in.
private func handOffPolicy() -> ClusterPlacementPolicy {
    var policy = ClusterPlacementPolicy(); policy.handOffModes = true
    return policy
}

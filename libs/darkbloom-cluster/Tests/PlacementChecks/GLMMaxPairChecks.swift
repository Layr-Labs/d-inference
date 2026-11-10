import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// GLM-5.3 Flash on two M5 Max 128 GB, whose serving pipeline ranks reserve
/// no request at LOAD (`ClusterModelLayout.requestsOnArrival`): the recorded
/// M5 Max's hardware (`Golden/profile-mac-b.json`: 40 GPU cores, 107.52 GiB
/// GPU working set by default) with its memory sampled idle or busy, at the
/// default GPU limit and raised to physical memory less 16 GiB
/// (`iogpu.wired_limit_mb=114688`, which Metal then reports as its working set).
/// Recorded inputs and constructed samples only: no model, no GPU.
func checkGLMMaxPair(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    guard let terms = layout.requestsOnArrival else {
        return checks.require("glm max: the GLM layout states how its requests are admitted on arrival", false)
    }
    checks.require("glm max: its load, request and last-rank allowances are the family's allowance split as the worker holds it",
        terms.loadAllowanceEveryRankBytes == 2_723_217_406 && terms.requestAllowanceEveryRankBytes == 7_308_009_462
            && terms.requestAllowanceLastRankBytes == 2_537_619_454)
    let recorded = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("profile-mac-b.json")))
    checks.require("glm max: the recorded Mac is an M5 Max 128 GB whose GPU keeps 107.52 GiB resident by default",
        recorded.chip == "Apple M5 Max" && recorded.gpuCores == 40 && recorded.physicalMemoryBytes == 128 << 30
            && recorded.gpuRecommendedWorkingSetBytes == 115_448_725_504 && recorded.wiredLimitBytes == nil)
    let raised = ClusterGPUMemoryLimit.ceilingBytes(physicalMemoryBytes: 128 << 30)
    func mac(_ label: String, freeGiB: Double? = nil, gpuBytes: Int? = nil, from p: ClusterDeviceProfile = recorded) throws
        -> ClusterPlacementDevice {
        var sample = SyntheticMac.idle(Double(p.physicalMemoryBytes >> 30))
        if let freeGiB { sample.freeGiB = freeGiB }
        let profile = try ClusterDeviceProfile(chip: p.chip, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores,
            gpuCores: p.gpuCores, osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: gpuBytes ?? p.gpuRecommendedWorkingSetBytes,
            gpuMaximumBufferBytes: p.gpuMaximumBufferBytes, allocatorLimitBytes: p.allocatorLimitBytes,
            memory: .gate(sample.observation, now: SyntheticMac.now), power: p.power, wiredLimitBytes: gpuBytes)
        return .init(label: label, profile: profile, speed: .assumedEqual)
    }
    var product = ClusterPlacementPolicy(); product.tensorParallelFirst = true; product.tensorParallelAssumesUnmeasuredLink = true
    func describe(_ c: ClusterPlacementCandidate?) -> String {
        c.map { "\($0.mode.rawValue) cut \($0.cut): " + $0.ranks.map { "\($0.device) \($0.fit) serving \($0.servingContextTokens ?? -1)" }
            .joined(separator: ", ") } ?? "none"
    }

    // Raised GPU limit, idle Macs: the pipeline places with both ranks loading now and a whole 65,536-token
    // request fitting each beside its weights; tensor parallel needs more than the Macs have.
    let raisedPair = try ["max-a", "max-b"].map { try mac($0, gpuBytes: raised) }
    let placed = try ClusterPlacementPlanner.plan(devices: raisedPair, layout: layout, policy: product)
    let chosen = placed.chosen
    checks.require("glm max, 2x M5 Max 128 GB at the raised GPU limit: a pipeline places, both ranks load now and admit 65,536 tokens now (\(describe(chosen)))",
        chosen?.mode == .pipeline && (23...25).contains(chosen?.cut ?? 0) && chosen?.ranks.count == 2
            && chosen?.ranks.allSatisfy({ $0.fit == .now && $0.servingContextTokens == 65_536 && $0.gpuWorkingSetShortBytes == nil }) == true)
    checks.require("glm max: tensor parallel does not fit two 128 GB Macs (\(placed.tensorParallel?.verdict.rawValue ?? "-"))",
        placed.tensorParallel?.verdict == .doesNotFit)
    let text = ClusterPlacementExplanation.describe(placed, devices: raisedPair, layout: layout)
    checks.require("glm max: the plan says each rank admits its requests as they arrive, up to 65,536 tokens now",
        text.filter { $0.contains("Its requests are admitted as they arrive: up to 65536 tokens of context fit now.") }.count == 2)
    // One Mac holding the whole model serves through its own engine, on the full quote: the plan estimates it as it
    // would without admission on arrival.
    var reserving = layout; reserving.requestsOnArrival = nil
    let alone = try ClusterPlacementPlanner.plan(devices: raisedPair, layout: reserving, policy: product).alone
    checks.require("glm max: one Mac alone is estimated on the full quote, not on admission on arrival",
        !alone.isEmpty && placed.alone == alone)

    // The over-count is gone: weights are the layout's allocator-bound loaded bytes (no page per tensor), and only the
    // last rank carries a chunk's logits.
    let cut24 = try ClusterPlacementPlanner.evaluate(devices: raisedPair, cuts: [24], mode: .pipeline, prefillSchedule: .serial, layout: layout)
    let memory = recorded.memory, context = layout.maximumContextTokens
    let ranges = [layout.range(0..<24), layout.range(24..<layout.layerCount)]
    checks.require("glm max, cut 24: each rank holds its range's loaded bytes and needs them, their construction copies and the load allowance with the gate's headroom",
        zip(cut24.ranks, ranges).allSatisfy { rank, range in
            rank.weightsBytes == range.loadedBytes
                && rank.needBytes == range.loadedBytes + range.requestWorkBytes + terms.loadAllowanceEveryRankBytes + memory.loadingHeadroomBytes
        })
    checks.require("glm max, cut 24: a request is its range's state with the request allowance, and the last rank's adds a chunk's logits",
        cut24.ranks[0].requestNeedBytes == ranges[0].stateBytes(tokens: context) + terms.requestAllowanceEveryRankBytes + memory.loadingHeadroomBytes
            && cut24.ranks[1].requestNeedBytes == ranges[1].stateBytes(tokens: context) + terms.requestAllowanceEveryRankBytes
                + terms.requestAllowanceLastRankBytes + memory.loadingHeadroomBytes)
    FileHandle.standardError.write(Data(("glm max 2x M5 Max 128 GB raised, cut 24: " + cut24.ranks.map {
        "rank \($0.rank) weights \($0.weightsBytes) need \($0.needBytes) request \($0.requestNeedBytes) serving \($0.servingContextTokens ?? -1)"
    }.joined(separator: "; ") + "\n").utf8))

    // Default GPU limit: only the cut whose ranks each hold their weights and a whole request in 107.52 GiB places.
    let defaultPair = try ["max-a", "max-b"].map { try mac($0) }
    let defaulted = try ClusterPlacementPlanner.plan(devices: defaultPair, layout: layout, policy: product).chosen
    checks.require("glm max, 2x M5 Max 128 GB at the default GPU limit: the pipeline places at cut 24 and admits 65,536 tokens now (\(describe(defaulted)))",
        defaulted?.mode == .pipeline && defaulted?.cut == 24
            && defaulted?.ranks.allSatisfy({ $0.fit == .now && $0.servingContextTokens == 65_536 }) == true)

    // Busy Macs: the load is admitted on what it needs; requests get the context that fits now, or none until memory frees.
    for (freeGiB, expectation) in [(105.0, "a shorter context"), (99.0, "no context")] {
        let busy = try ["max-a", "max-b"].map { try mac($0, freeGiB: freeGiB, gpuBytes: raised) }
        let ranks = try ClusterPlacementPlanner.evaluate(devices: busy, cuts: [24], mode: .pipeline, prefillSchedule: .serial, layout: layout).ranks
        let serving = ranks.compactMap(\.servingContextTokens)
        checks.require("glm max, \(Int(freeGiB) + 1) GiB admissible: cut 24 still loads now and its requests get \(expectation) now (\(serving))",
            ranks.allSatisfy { $0.fit == .now } && serving.count == 2
                && (freeGiB > 100 ? serving.allSatisfy { $0 > 2049 && $0 < 65_536 } : serving.allSatisfy { $0 == 0 }))
    }

    // A GPU limit below what a rank must keep resident refuses, and the refusal names the limit, not free memory.
    let low = try ["max-a", "max-b"].map { try mac($0, gpuBytes: 100 << 30) }
    let gpuRefused = try ClusterPlacementPlanner.plan(devices: low, layout: layout, policy: product)
    let gpuText = ClusterPlacementExplanation.describe(gpuRefused, devices: low, layout: layout)
    checks.require("glm max, a 100 GiB GPU limit: refused, each short rank naming the GPU's limit and the closing line saying raising it changes the answer",
        gpuRefused.chosen == nil && gpuRefused.refusal?.closest?.ranks.contains { $0.gpuWorkingSetShortBytes != nil } == true
            && gpuText.contains { $0.contains("raising the GPU's limit can") }
            && gpuText.contains { $0.hasPrefix("  What a Mac's GPU keeps resident decides this") }
            && !gpuText.contains { $0.contains("cannot change this") })

    // Two 64 GB Macs cannot hold half of GLM whatever is freed or raised: refused as before, without a GPU remedy.
    let small = try ["max-a", "max-b"].map { try mac($0, from: try SyntheticMac.idle(64).profile(chip: "Apple M5 Max")) }
    let tooSmall = try ClusterPlacementPlanner.plan(devices: small, layout: layout, policy: product)
    let smallText = ClusterPlacementExplanation.describe(tooSmall, devices: small, layout: layout)
    checks.require("glm max, 2x 64 GB: refused, no GPU limit offered as the remedy, and the line says freeing memory cannot change it",
        tooSmall.chosen == nil && tooSmall.refusal?.closest?.ranks.allSatisfy({ $0.gpuWorkingSetShortBytes == nil }) != false
            && smallText.contains { $0.contains("Freeing memory on these Macs cannot change this") }
            && !smallText.contains { $0.contains("raising the GPU's limit") })
}

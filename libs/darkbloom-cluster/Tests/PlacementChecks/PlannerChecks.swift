import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The profile's reduction of the gate is exact: over constructed Macs and
/// requirements, `memory.admits` is the gate's own `decide(...).admitted`.
func checkGateAgreement(_ checks: PlacementChecks) {
    var macs: [SyntheticMac] = []
    for physical in [8.0, 16, 32, 64, 128, 256, 512] {
        for free in [0.005, 0.02, 0.3, 4, 20, physical * 0.5] where free < physical - 6 {
            for cache in [0.0, 2, physical * 0.2, physical * 0.55] where free + cache < physical - 5 {
                for active in [0.0, physical * 0.2] where free + cache + active < physical - 5 {
                    for pressure in [1, 2] {
                        macs.append(.init(physicalGiB: physical, freeGiB: free, inactiveCacheGiB: cache, activeCacheGiB: active,
                            wiredGiB: 4, pressure: pressure))
                    }
                }
            }
        }
    }
    macs.append(.init(physicalGiB: 128, freeGiB: 1, inactiveCacheGiB: 80, pressure: 2, swapGiB: 3))  // not judged
    macs.append(.init(physicalGiB: 128, freeGiB: 1, inactiveCacheGiB: 80, pressure: 4))             // not judged
    var compared = 0, disagreements = 0, admitted = 0, unjudged = 0
    for mac in macs {
        let os = mac.observation
        let memory = ClusterDeviceMemory.gate(os, now: SyntheticMac.now)
        if !memory.judged { unjudged += 1 }
        let physical = Int(mac.physicalGiB * Double(gib))
        var requirements = [0, 1, 6 * gib - 1, 6 * gib, 6 * gib + 1, physical - 1, physical, physical + 1, 2 * physical]
        requirements += [memory.admissibleNowBytes - 1, memory.admissibleNowBytes, memory.admissibleNowBytes + 1].filter { $0 >= 0 }
        requirements += stride(from: gib, through: physical, by: max(gib, physical / 37)).map { $0 }
        for required in requirements {
            let gate = (try? QwenDenseStageLoadPolicy.decide(os, requiredBytes: required, purpose: "check", now: SyntheticMac.now))?.admitted ?? false
            if gate != memory.admits(required) { disagreements += 1 }
            if gate { admitted += 1 }
            // The four answers are consistent with the gate's decision too.
            if (memory.fit(required) == .now) != gate { disagreements += 1 }
            compared += 1
        }
    }
    checks.require("gate agreement: \(compared) decisions over \(macs.count) constructed Macs, none differ", disagreements == 0)
    checks.require("gate agreement sweep admits some and refuses some", admitted > 500 && admitted < compared - 500)
    checks.require("gate agreement sweep includes samples the gate will not judge", unjudged >= 2)
    // The record carries the gate's constants, not copies.
    let memory = ClusterDeviceMemory.gate(SyntheticMac.idle(64).observation, now: SyntheticMac.now)
    checks.require("the record carries the gate's own constants",
        memory.gatePolicy == QwenDenseStageLoadPolicy.identifier
            && memory.minimumAdmissibleBytes == QwenDenseStageLoadPolicy.minimumAdmissibleBytes(physicalMemoryBytes: memory.physicalMemoryBytes)
            && memory.minimumTrulyFreeBytes == QwenDenseStageLoadPolicy.minimumTrulyFreeBytes
            && memory.loadingHeadroomBytes == QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: memory.physicalMemoryBytes)
            && memory.allocatorHeadroomBytes == QwenDenseStageLoadPolicy.allocatorHeadroomBytes
            && memory.loadScratchBytes == CheckpointAlignedReadPlan.maximumScratchAllocationBytes)
    // The two margins scale with the Mac below 96 GiB, never under their least; at 96 GiB and more they are the measured
    // 6 and 4 GiB (owner 2026-10-15: one Gemma layer on a 36 GB Mac was refused by a fixed 6 GiB floor).
    typealias Policy = QwenDenseStageLoadPolicy
    let gib = 1 << 30
    checks.require("margins: 36 GiB Mac 2.25 / 1.5 GiB",
        Policy.minimumAdmissibleBytes(physicalMemoryBytes: 36 * gib) == 9 * gib / 4
            && Policy.loadingHeadroomBytes(physicalMemoryBytes: 36 * gib) == 3 * gib / 2)
    checks.require("margins: 64 GiB Mac 4 GiB floor",
        Policy.minimumAdmissibleBytes(physicalMemoryBytes: 64 * gib) == 4 * gib)
    checks.require("margins: 96 and 256 GiB Macs keep the measured 6 / 4 GiB",
        [96, 256].allSatisfy { Policy.minimumAdmissibleBytes(physicalMemoryBytes: $0 * gib) == 6 * gib
            && Policy.loadingHeadroomBytes(physicalMemoryBytes: $0 * gib) == 4 * gib })
    checks.require("margins: a small Mac never under 2 / 1.5 GiB",
        Policy.minimumAdmissibleBytes(physicalMemoryBytes: 8 * gib) == 2 * gib
            && Policy.loadingHeadroomBytes(physicalMemoryBytes: 8 * gib) == 3 * gib / 2)
    let small = ClusterDeviceMemory.gate(SyntheticMac.idle(36).observation, now: SyntheticMac.now)
    checks.require("margins: a 36 GiB Mac's record carries its own margins",
        small.minimumAdmissibleBytes == 9 * gib / 4 && small.loadingHeadroomBytes == 3 * gib / 2)
    // A cache-heavy Mac: the gate counts all of its file cache, and the record shows it.
    let heavyMac = SyntheticMac(physicalGiB: 256, freeGiB: 0.3, inactiveCacheGiB: 180)
    let heavy = ClusterDeviceMemory.gate(heavyMac.observation, now: SyntheticMac.now)
    checks.require("a cache-heavy Mac at normal pressure counts all of its file cache",
        heavy.countedFileCacheBytes == heavy.fileBackedBytes && heavy.fileBackedBytes == 180 * gib
            && heavy.admissibleNowBytes == heavy.actualFreeBytes + heavy.fileBackedBytes)
    // 0.3 GiB free, 180 GiB of idle cache, about 72 GiB of applications: the kernel keeps
    // 10/27 of what is pageable (about 93 GiB) as cache and would give up the rest (about 87).
    checks.require("the record carries the kernel's cache minimum and what lies above it, as the gate computed them",
        heavy.fileCacheReserveBytes + heavy.fileCacheAboveReserveBytes == heavy.fileBackedBytes
            && abs(heavy.fileCacheReserveBytes - 252 * gib * 10 / 27) < gib / 64)
    checks.require("cache below the kernel's minimum is counted too: a requirement beyond free pages plus the cache above it is admitted now",
        heavy.kernelWouldGiveBytes < 170 * gib && heavy.fit(170 * gib) == .now)
    // The same Mac at warning pressure: the gate counts no cache, though the kernel would give it up.
    var warnedMac = heavyMac; warnedMac.pressure = 2
    let warned = ClusterDeviceMemory.gate(warnedMac.observation, now: SyntheticMac.now)
    checks.require("at warning pressure the same Mac counts none of its file cache",
        warned.judged && warned.countedFileCacheBytes == 0 && warned.admissibleNowBytes == warned.actualFreeBytes)
    checks.require("within free pages plus cache above the kernel's minimum, beyond what the gate counts: the gate's rule refuses, not memory",
        { if case .gateCountsLess = warned.fit(80 * gib) { return true } else { return false } }())
    checks.require("beyond the cache the kernel would give up: applications must release memory, and protected cache is not promised",
        { if case .afterApplicationsRelease(let bytes) = warned.fit(100 * gib) { return bytes == 100 * gib - warned.kernelWouldGiveBytes } else { return false } }())
    checks.require("beyond everything but the kernel's cache minimum: the minimum is named as the kernel's share of unwired memory, not as something only a restart empties",
        { if case .afterRestart = heavy.fit(200 * gib) { return true } else { return false } }()
            && ClusterPlacementExplanation.describe(heavy.fit(200 * gib)).contains("in proportion to the memory that is not wired")
            && !ClusterPlacementExplanation.describe(heavy.fit(200 * gib)).contains("Only a restart"))
    checks.require("beyond everything that is not wired: never",
        { if case .never = heavy.fit(253 * gib) { return true } else { return false } }())
    checks.require("a requirement beyond physical memory is answered: never",
        { if case .never = heavy.fit(257 * gib) { return true } else { return false } }())
}

func checkLayoutBuilder(_ checks: PlacementChecks) throws {
    let layout = try syntheticLayout(layers: 8, layerGiB: 1)
    checks.require("a built layout conserves bytes", layout.wholeModelLoadedBytes == 9 * gib && layout.excluded.storedBytes == 0)
    checks.require("a range holding the first layer holds the ingress and no egress",
        layout.range(0..<3).loadedBytes == 3 * gib + gib / 2 && layout.range(3..<8).loadedBytes == 5 * gib + gib / 2
            && layout.range(2..<5).loadedBytes == 3 * gib)
    checks.require("a layout survives its own encoding", try ClusterModelLayout.decode(layout.encoded()) == layout)
    let tensors = SyntheticFamily.tensors(layerBytes: Array(repeating: gib, count: 8), embed: gib, head: gib, largestTensor: gib)
    var scattered = SyntheticFamily(layerCount: 8, admittedCuts: [2, 4, 6]); scattered.scatter = true
    checks.refuses("a family whose plan scatters a layer is refused", because: "not a contiguous layer pipeline") {
        _ = try ClusterModelLayoutBuilder.build(family: scattered, tensors: tensors, artifactSHA256: "", configurationSHA256: "")
    }
    checks.refuses("a tensor the family does not know is refused", because: "Unknown tensor") {
        _ = try ClusterModelLayoutBuilder.build(family: SyntheticFamily(layerCount: 8, admittedCuts: [4]),
            tensors: tensors + [.init(name: "stray.weight", byteCount: 1)], artifactSHA256: "", configurationSHA256: "")
    }
    checks.refuses("a layer with no tensor is refused", because: "A layer has no stored tensor") {
        _ = try ClusterModelLayoutBuilder.build(family: SyntheticFamily(layerCount: 9, admittedCuts: [4]),
            tensors: tensors, artifactSHA256: "", configurationSHA256: "")
    }
    checks.refuses("admitted cuts outside the plan's cuts are refused", because: "A layout needs") {
        _ = try ClusterModelLayoutBuilder.build(family: SyntheticFamily(layerCount: 8, admittedCuts: [5], structural: [2, 4, 6]),
            tensors: tensors, artifactSHA256: "", configurationSHA256: "")
    }
    // A tied embedding is stored once and held by both ends.
    var tied = SyntheticFamily(layerCount: 8, admittedCuts: Array(1..<8)); tied.tiedEmbedding = true; tied.unevenCost = true
    let tiedLayout = try ClusterModelLayoutBuilder.build(family: tied, tensors: tensors, artifactSHA256: "", configurationSHA256: "")
    checks.require("a tensor both ends load is stored once and held by the first and the last range",
        tiedLayout.ingress.loadedBytes == gib && tiedLayout.egress.loadedBytes == 2 * gib && tiedLayout.egress.storedBytes == gib
            && tiedLayout.range(0..<4).loadedBytes == 5 * gib && tiedLayout.range(4..<8).loadedBytes == 6 * gib
            && tiedLayout.range(2..<6).loadedBytes == 4 * gib)
    checks.require("a family's measured layer costs reach the layout", tiedLayout.range(0..<4).cost == 6 && tiedLayout.layers[1].cost == 2)
    // The surveyed table: bytes on each side at each cut of the resident row.
    let mimo = try surveyedMiMoLayout()
    func gibText(_ bytes: Int) -> Double { (Double(bytes) / Double(gib) * 100).rounded() / 100 }
    let table: [(Int, Double, Double)] = [(24, 76.39, 79.39), (26, 82.96, 72.82), (28, 89.52, 66.25),
                                          (30, 96.08, 59.69), (32, 102.65, 53.13), (34, 109.21, 46.56)]
    for (cut, first, last) in table {
        checks.require("surveyed model at cut \(cut) holds \(first) and \(last) GiB",
            abs(gibText(mimo.range(0..<cut).loadedBytes) - first) <= 0.02 && abs(gibText(mimo.range(cut..<48).loadedBytes) - last) <= 0.02)
    }
}

/// The registered models' layouts from retained header metadata, against
/// figures real loads recorded.
func checkRegisteredLayouts(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws -> (nine: ClusterModelLayout, twentySeven: ClusterModelLayout) {
    let nine = try ClusterPlacementLayouts.layout(configuration: inputs.nine.configuration, tensors: inputs.nine.stored)
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    checks.require("9B layout: 32 layers, its registered bytes, the four admitted cuts and seven plan cuts",
        nine.layerCount == 32 && nine.wholeModelLoadedBytes == 5_038_041_600 && nine.admittedCuts == [4, 8, 12, 16]
            && nine.structuralCuts == [4, 8, 12, 16, 20, 24, 28] && nine.runtimeModelID == "registered_qwen35_9b")
    checks.require("27B layout: 64 layers, its registered bytes, fifteen cuts",
        big.layerCount == 64 && big.wholeModelLoadedBytes == 15_132_802_048 && big.admittedCuts == Array(stride(from: 4, through: 60, by: 4))
            && big.structuralCuts == big.admittedCuts && big.runtimeModelID == "registered_qwen38_27b")
    // The runtime executes tensor parallel on both dense rows (`QwenTensorParallelResidentRuntime`), not the
    // pipeline-prefill/tensor-decode hybrid; every other mode, the pipeline's speculative rounds included.
    let executed = ClusterGenerationMode.allCases.filter { $0 != .pipelinePrefillTensorDecode }
    checks.require("both list every generation mode the runtime executes (tensor parallel, not the hybrid) and both prefill schedules",
        nine.generationModes == executed && big.generationModes == executed
            && nine.prefillSchedules == [.serial, .oneChunkLookahead])
    // Stage sizes recorded by verified loads of the 27B (active bytes loaded).
    func loadedGiB(_ layout: ClusterModelLayout, _ range: Range<Int>) -> Double { Double(layout.range(range).loadedBytes) / Double(gib) }
    for (cut, first, last) in [(12, 3.059, 11.035), (16, 3.857, 10.238), (20, 4.654, 9.440)] {
        checks.require("27B cut \(cut): stages are the \(first) and \(last) GiB real loads recorded",
            abs(loadedGiB(big, 0..<cut) - first) < 0.002 && abs(loadedGiB(big, cut..<64) - last) < 0.002)
    }
    checks.require("9B cut 4: the upper stage is the 3.71 GiB real loads recorded", abs(loadedGiB(nine, 4..<32) - 3.71) < 0.005)
    // The request state of each model, against the figures the engine design
    // records: 51.5 MB fixed and 32,768 B per token for the 9B.
    let state = nine.range(0..<32)
    checks.require("9B request state: 32,768 B per token and 51.5 MB fixed",
        state.stateBytesPerToken == 32_768 && abs(Double(state.stateFixedBytes) / 1e6 - 51.5) < 0.1)
    // The first ask of the load gate, as real refusals and admissions printed it.
    let memory = ClusterDeviceMemory.gate(SyntheticMac.idle(128).observation, now: SyntheticMac.now)
    func firstAsk(_ layout: ClusterModelLayout, _ range: Range<Int>) -> Double {
        let part = layout.range(range)
        return Double(max(memory.minimumAdmissibleBytes, part.loadedBytes + part.tensorCount * memory.pageSizeBytes
            + 2 * part.largestTensorBytes + memory.loadScratchBytes + memory.loadingHeadroomBytes)) / Double(gib)
    }
    checks.require("27B rank 1 at cut 16: the load gate's first ask is the 15.46 GiB it printed", abs(firstAsk(big, 16..<64) - 15.46) <= 0.03)
    checks.require("27B rank 1 at cut 4: the 17.86 GiB it printed", abs(firstAsk(big, 4..<64) - 17.86) <= 0.03)
    checks.require("27B rank 1 at cut 60: the 6.66 GiB it printed", abs(firstAsk(big, 60..<64) - 6.66) <= 0.03)
    checks.require("9B rank 1 at cut 4: the 8.68 GiB it printed", abs(firstAsk(nine, 4..<32) - 8.68) <= 0.03)
    checks.refuses("headers that are not the registered inventory are refused", because: "not the registered model's inventory") {
        _ = try ClusterPlacementLayouts.layout(configuration: inputs.nine.configuration, tensors: Array(inputs.nine.stored.dropLast()))
    }
    return (nine, big)
}

/// Every placement of two devices, by plain loops, each evaluated alone.
func everyPlacement(_ devices: [ClusterPlacementDevice], _ layout: ClusterModelLayout,
                    cuts: [Int], policy: ClusterPlacementPolicy = .init()) throws -> [ClusterPlacementCandidate] {
    var result: [ClusterPlacementCandidate] = []
    for order in [[devices[0], devices[1]], [devices[1], devices[0]]] {
        for cut in cuts {
            // The hand-off modes are planned only under the opt-in (sharded deployments only by default).
            // Tensor parallel cuts no layer range and needs a measured reduction: not a placement at a cut.
            for mode in layout.generationModes where (policy.handOffModes || !mode.isHandOff) && !mode.usesTensorParallelPrefill {
                result.append(try ClusterPlacementPlanner.evaluate(devices: order, cuts: [cut], mode: mode,
                    prefillSchedule: .oneChunkLookahead, layout: layout, policy: policy))
            }
        }
    }
    return result
}

/// The owner's rule, checked without the planner's own enumeration: a model
/// is refused exactly when no order, cut and mode is possible, and the
/// chosen placement is the fastest the hardware holds. Live memory never
/// moves it (owner, 2026-10-18): the same Macs at rest get the same split.
func checkRule(_ name: String, _ devices: [ClusterPlacementDevice], _ layout: ClusterModelLayout,
               _ checks: PlacementChecks, policy: ClusterPlacementPolicy = .init()) throws -> ClusterPlacementResult {
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
    let all = try everyPlacement(devices, layout, cuts: layout.admittedCuts, policy: policy)
    let possible = all.filter(\.possible)
    let aloneHolds = result.alone.contains { $0.fit.possible }
    checks.require("\(name): a division is chosen exactly when one is possible (\(possible.count) of \(all.count) are), and the model is refused exactly when none is and no Mac holds it alone",
        (result.chosen == nil) == possible.isEmpty && (result.refusal != nil) == (possible.isEmpty && !aloneHolds))
    // The fastest split that loads now; only when none does, the fastest the hardware holds (owner, 2026-10-19).
    let loadsNow = possible.filter { $0.tier == 0 && $0.withinGPUWorkingSet == (result.chosen?.withinGPUWorkingSet ?? true) }
    if !loadsNow.isEmpty {
        checks.require("\(name): a split loads now, so the chosen split is one that does", result.chosen?.tier == 0)
    }
    if let chosen = result.chosen {
        let best = possible.filter { $0.withinGPUWorkingSet == chosen.withinGPUWorkingSet && ($0.tier == 0) == (chosen.tier == 0) }
        checks.require("\(name): the chosen placement is one the hardware holds, and none in its group is predicted faster",
            chosen.possible && (chosen.withinGPUWorkingSet || !possible.contains(where: \.withinGPUWorkingSet))
                && best.allSatisfy { $0.routedSeconds(result.regime) >= chosen.routedSeconds(result.regime) })
        checks.require("\(name): the chosen placement is one of the enumerated ones", all.contains(chosen))
        // MTP on by default where it pays: a chosen phase split runs the
        // model's head exactly when its decoding Mac prefers the head.
        let decoder = devices.first { $0.label == chosen.ranks.last?.device }
        checks.require("\(name): a chosen phase split runs the speculative head exactly when the decoding Mac prefers it",
            !chosen.mode.isPhaseSplit || chosen.mode.usesSpeculativeHead
                == (decoder.map { ClusterSpeculativeCredit.prefersHead($0.speed.rested, device: $0, layout: layout) } ?? false))
    }
    checks.require("\(name): the planner considered every placement", result.candidatesConsidered == all.count)
    checks.require("\(name): planning twice gives the same answer", try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy) == result)
    return result
}

func checkDeviceMixes(_ nine: ClusterModelLayout, _ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let mimo = try surveyedMiMoLayout()
    func share(_ c: ClusterPlacementCandidate, of label: String) -> Int { c.ranks.first { $0.device == label }.map { $0.endLayer - $0.firstLayer } ?? -1 }

    // Equal pairs: nothing distinguishes the Macs, so the layers divide evenly.
    for size in [24.0, 64, 128] {
        let devices = [try SyntheticMac.idle(size).device("a"), try SyntheticMac.idle(size).device("b")]
        let result = try checkRule("equal pair \(Int(size)) + \(Int(size)), 27B", devices, big, checks)
        if size >= 64 {
            checks.require("equal pair \(Int(size)): fits now at the even cut, first device first",
                result.chosen?.tier == 0 && result.chosen?.cut == 32 && result.chosen?.ranks.first?.device == "a")
        } else {
            checks.require("equal pair 24: still placed, each Mac holding what it can admit",
                result.chosen != nil && (result.chosen?.ranks.allSatisfy { $0.needBytes <= 24 * gib } ?? false))
        }
    }

    // 16 + 64: the even cut needs more than a 16 GiB Mac admits at rest (its
    // unwired memory less the kernel's file-cache minimum, 8.5 GiB here); a
    // smaller share does not. At the earlier reference request (8,192
    // prompt, 128 output): at the model's largest (32,767 and 4,096) the whole
    // model's state charged to either rank alone leaves a 16 GiB Mac too little.
    do {
        let devices = [try SyntheticMac.idle(16).device("small"), try SyntheticMac.idle(64).device("large")]
        var reference = ClusterPlacementPolicy(); reference.promptTokens = 8192; reference.outputTokens = 128
        let result = try checkRule("16 + 64, 27B", devices, big, checks, policy: reference)
        let even = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [32], mode: .pipeline, prefillSchedule: .oneChunkLookahead,
                                                        layout: big, policy: reference)
        checks.require("16 + 64: the even cut does not fit the 16 GiB Mac now", even.tier > 0)
        checks.require("16 + 64: the small Mac holds the smaller share, within what it admits now, and it is placed now",
            share(result.chosen!, of: "small") < share(result.chosen!, of: "large")
                && result.chosen!.ranks.allSatisfy { $0.fit == .now }
                && result.chosen!.ranks.first(where: { $0.device == "small" })!.needBytes <= devices[0].profile.memory.admissibleNowBytes)
        checks.require("16 + 64: the small Mac is not asked to hold the whole model for a phase split",
            !(result.chosen!.mode.isPhaseSplit && result.chosen!.ranks.last!.device == "small"))
        let nineResult = try checkRule("16 + 64, 9B", devices, nine, checks)
        checks.require("16 + 64, 9B: placed now", nineResult.chosen?.tier == 0)
    }

    // 64 + 512 and the 173 GB model: even the highest admitted cut leaves the
    // small Mac more than the 38.7 GiB it admits at rest.
    do {
        let devices = [try SyntheticMac.idle(64).device("small"), try SyntheticMac.idle(512).device("large")]
        let result = try checkRule("64 + 512, surveyed 173 GB model", devices, mimo, checks)
        // No admitted cut is within the small Mac's at-rest ceiling, but an idle small Mac admits a
        // share now, so the model is divided at a cut that loads now (owner, 2026-10-19).
        checks.require("64 + 512: divided at a cut both Macs load now; not refused, and the large Mac could hold it alone",
            result.chosen?.ranks.allSatisfy { $0.fit == .now } == true && result.refusal == nil
                && result.alone.first { $0.device == "large" }?.fit == .now)
        checks.require("64 + 512: the output names the chosen placement",
            ClusterPlacementExplanation.describe(result, devices: devices, layout: mimo).joined(separator: "\n").contains("Chosen placement"))
        let smallFirst = try everyPlacement(devices, mimo, cuts: mimo.admittedCuts).filter { $0.ranks.first?.device == "small" }
        let smallFirstAnywhere = try everyPlacement(devices, mimo, cuts: mimo.structuralCuts).filter { $0.ranks.first?.device == "small" }
        checks.require("64 + 512: the small Mac cannot be first at any admitted cut, and could be at a cut the plan could make",
            smallFirst.allSatisfy { !$0.possible } && smallFirstAnywhere.contains(where: \.possible) && result.bestStructural != nil)
        _ = try checkRule("64 + 512, 27B", devices, big, checks)
    }

    // 128 + 256, this pair's sizes: every registered model and the 173 GB one.
    do {
        let devices = [try SyntheticMac.idle(256).device("a"), try SyntheticMac.idle(128).device("b")]
        for (name, layout) in [("9B", nine), ("27B", big), ("surveyed 173 GB model", mimo)] {
            let result = try checkRule("128 + 256, \(name)", devices, layout, checks)
            checks.require("128 + 256, \(name): placed now", result.chosen?.tier == 0)
        }
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: mimo)
        // The even cut's half needs 85 GiB: more than the 128 GiB Mac admits at rest (78 GiB),
        // within what the idle Mac admits now, so it may hold up to the even share (owner, 2026-10-19).
        let layers = result.chosen.map { c in c.ranks.map { (device: $0.device, count: $0.endLayer - $0.firstLayer) } }
        let held = (b: layers?.first { $0.device == "b" }?.count ?? .max, a: layers?.first { $0.device == "a" }?.count ?? 0)
        checks.require("128 + 256, surveyed model: the 128 GiB Mac holds no more layers than the even cut gives it (b \(held.b), a \(held.a))",
            held.b <= held.a)
        checks.require("128 + 256, surveyed model: both ranks load now", result.chosen?.ranks.allSatisfy { $0.fit == .now } ?? false)
        checks.require("128 + 256, surveyed model: the 128 GiB Mac cannot hold the model alone, the 256 GiB Mac can now",
            result.alone.first { $0.device == "b" }?.fit.possible == false && result.alone.first { $0.device == "a" }?.fit == .now)
    }

    // A tiny and a huge Mac.
    do {
        // An 8 GiB Mac admits 3.8 GiB at rest, less than the smallest share needs: no division, and the
        // model is not refused, because the huge Mac holds it alone.
        let eight = [try SyntheticMac.idle(8).device("tiny"), try SyntheticMac.idle(512).device("huge")]
        let alone = try checkRule("8 + 512, 27B", eight, big, checks)
        checks.require("8 + 512: no share is within what the 8 GiB Mac admits at rest; not refused, the huge Mac holds it alone",
            alone.chosen == nil && alone.refusal == nil && alone.alone.first { $0.device == "huge" }?.fit == .now)
        checks.require("8 + 512: the output says one Mac holds the model alone",
            ClusterPlacementExplanation.describe(alone, devices: eight, layout: big).joined(separator: "\n").contains("huge alone needs"))
        let devices = [try SyntheticMac.idle(12).device("tiny"), try SyntheticMac.idle(512).device("huge")]
        let result = try checkRule("12 + 512, 27B", devices, big, checks)
        // The margins scale with the Mac (owner 2026-10-15: shard whatever is possible), so a 12 GiB Mac takes the
        // smallest share; the huge Mac could still hold the model alone.
        let layers = { (c: ClusterPlacementCandidate, d: String) in c.ranks.first { $0.device == d }.map { $0.endLayer - $0.firstLayer } ?? 0 }
        checks.require("12 + 512: divided, the tiny Mac holding the smaller share",
            result.chosen.map { layers($0, "tiny") >= 1 && layers($0, "tiny") < layers($0, "huge") } ?? false)
        checks.require("12 + 512: the huge Mac could still hold it alone", result.alone.first { $0.device == "huge" }?.fit == .now)
        // A small Mac that is nearly full (its wired memory as at rest): divided as at rest, its rank reporting
        // that it does not fit as it runs now.
        let full = [try SyntheticMac(physicalGiB: 12, freeGiB: 0.4, inactiveCacheGiB: 0.2, wiredGiB: 2.5).device("tiny"),
                    try SyntheticMac.idle(512).device("huge")]
        let crowded = try checkRule("12 (nearly full) + 512, 27B", full, big, checks)
        checks.require("12 (nearly full) + 512: divided as the idle pair is, the tiny Mac's rank saying it does not fit now; not refused",
            crowded.chosen?.cuts == result.chosen?.cuts && crowded.chosen?.ranks.map(\.device) == result.chosen?.ranks.map(\.device)
                && crowded.refusal == nil && (crowded.chosen?.ranks.first { $0.device == "tiny" }?.fit.tier ?? 0) > 0
                && crowded.alone.first { $0.device == "huge" }?.fit == .now)
        checks.require("12 (nearly full) + 512: the output still says what each Mac alone needs",
            ClusterPlacementExplanation.describe(crowded, devices: full, layout: big).joined(separator: "\n").contains("Each Mac alone, for comparison\n  tiny: needs"))
    }

    // A model larger than the pair.
    do {
        let devices = [try SyntheticMac.idle(64).device("a"), try SyntheticMac.idle(64).device("b")]
        let result = try checkRule("64 + 64, surveyed 173 GB model", devices, mimo, checks)
        checks.require("64 + 64: refused, with what each Mac could hold, the layers left over and no boundary that would change it",
            result.chosen == nil && result.refusal?.devices.count == 2
                && result.refusal?.fitsAtAStructuralCut == false && result.refusal?.fitsAtSomeLayerBoundary == false
                && (result.refusal?.uncoveredLayers ?? 0) > 0
                && (result.refusal?.devices.allSatisfy { $0.mostLayersAsFirst > 0 && $0.mostLayersAsFirst < 24 && $0.mostBytesAsLast < 64 * gib } ?? false)
                && (result.refusal?.closest?.ranks.contains { !$0.fit.possible } ?? false))
        let text = ClusterPlacementExplanation.describe(result, devices: devices, layout: mimo).joined(separator: "\n")
        checks.require("64 + 64: the refusal says freeing memory cannot change it", text.contains("Freeing memory on these Macs cannot change this"))
        let close = [try SyntheticMac.idle(96).device("a"), try SyntheticMac.idle(64).device("b")]
        let closeResult = try checkRule("96 + 64 (160 GiB for a 156 GiB model)", close, mimo, checks)
        checks.require("96 + 64: refused although the weights alone would fit, because each load needs its headroom", closeResult.chosen == nil)
    }

    // A model that fits one way round only: its head is larger than the small Mac (and within
    // the 38.7 GiB the large one admits at rest).
    do {
        var family = SyntheticFamily(layerCount: 8, admittedCuts: Array(1..<8))
        family.generationModes = [.pipeline]
        let layout = try ClusterModelLayoutBuilder.build(family: family,
            tensors: SyntheticFamily.tensors(layerBytes: Array(repeating: gib / 2, count: 8), embed: gib / 2, head: 30 * gib, largestTensor: gib / 2),
            artifactSHA256: "", configurationSHA256: "")
        for labels in [["small", "large"], ["large", "small"]] {
            let devices = try labels.map { try SyntheticMac.idle($0 == "small" ? 16 : 64).device($0) }
            let result = try checkRule("one way round, devices given as \(labels.joined(separator: ", "))", devices, layout, checks)
            checks.require("one way round (\(labels[0]) given first): the large Mac is last whichever was named first",
                result.chosen?.tier == 0 && result.chosen?.ranks.last?.device == "large")
        }
    }

    // Memory mostly in file cache.
    do {
        let cached = SyntheticMac(physicalGiB: 256, freeGiB: 0.3, inactiveCacheGiB: 190, wiredGiB: 8)
        let devices = [try cached.device("a"), try SyntheticMac(physicalGiB: 128, freeGiB: 0.4, inactiveCacheGiB: 90, wiredGiB: 6).device("b")]
        let small = try checkRule("cache-heavy 128 + 256, 27B", devices, big, checks)
        checks.require("cache-heavy pair, 27B: placed now on counted file cache", small.chosen?.tier == 0)
        let large = try checkRule("cache-heavy 128 + 256, surveyed 173 GB model", devices, mimo, checks)
        // The cut chosen at rest. The 256 GiB Mac's share is within its free pages and unprotected
        // cache; the 128 GiB Mac's is not, since the kernel keeps 45 GiB of its 90 GiB of cache.
        checks.require("cache-heavy pair, 173 GB model: not refused; each rank says what is in its way, and they differ",
            large.refusal == nil && large.chosen?.cut == 28 && large.chosen?.tier == 2
                && { if case .gateCountsLess = large.chosen!.ranks[0].fit { return true } else { return false } }()
                && { if case .afterApplicationsRelease = large.chosen!.ranks[1].fit { return true } else { return false } }())
        let text = ClusterPlacementExplanation.describe(large, devices: devices, layout: mimo).joined(separator: "\n")
        checks.require("cache-heavy pair: the output names free pages, applications and the kernel's cache minimum apart, and says the gate decides at load",
            text.contains("Nothing has to close") && text.contains("applications would have to release")
                && text.contains("as its minimum now (a share of the memory that is not wired: it falls as memory is wired, not when applications close)")
                && !text.contains("short of a restart") && text.contains("The load gate on each Mac decides when it loads"))
        // Cache that is in use (active) is not counted by the gate, and the plan says the same.
        let busy = [try SyntheticMac(physicalGiB: 256, freeGiB: 0.3, inactiveCacheGiB: 20, activeCacheGiB: 170, wiredGiB: 8).device("a"), devices[1]]
        let busyResult = try checkRule("256 GiB Mac whose cache is active, 27B", busy, big, checks)
        checks.require("active cache: the 256 GiB Mac counts none of it",
            busy[0].profile.memory.countedFileCacheBytes == 0 && (busyResult.chosen?.tier ?? 0) >= 1)
    }

    // Memory wired by a running program (another account's model server held 222.9 GiB of
    // a 256 GiB Mac on 2026-10-11): the words must not say freeing cannot help.
    do {
        let busy = SyntheticMac(physicalGiB: 256, freeGiB: 7, inactiveCacheGiB: 10, wiredGiB: 222)
        let devices = [try SyntheticMac(physicalGiB: 256, freeGiB: 87, inactiveCacheGiB: 60, wiredGiB: 10).device("a"), try busy.device("b")]
        checks.require("wired memory: a quarter of physical memory or less is the system's; more is a running program's",
            !devices[0].profile.memory.wiredLooksHeldByAProgram && devices[1].profile.memory.wiredLooksHeldByAProgram)
        let result = try checkRule("256 GiB Mac with 222 GiB wired beside an ordinary 256 GiB Mac, surveyed 173 GB model", devices, mimo, checks)
        let text = ClusterPlacementExplanation.describe(result, devices: devices, layout: mimo).joined(separator: "\n")
        let lines = text.split(separator: "\n")
        checks.require("wired by a program: the busy Mac's answer says stopping the program frees it, never 'whatever is freed'",
            lines.contains { $0.contains("b: needs") && $0.contains("of all the memory that is not wired") && $0.contains("stopping that program gives it back") }
                && !text.contains("whatever is freed"))
        checks.require("wired by a program: the device line names it for the busy Mac only",
            lines.filter { $0.contains("wired is far more than macOS keeps wired at rest") }.count == 1)
        checks.require("wired by a program: the ordinary Mac's answer keeps its usual words",
            lines.contains { $0.contains("a: needs") && !$0.contains("running program") })
        let both = [try busy.device("a"), try SyntheticMac(physicalGiB: 256, freeGiB: 4, inactiveCacheGiB: 4, wiredGiB: 230).device("b")]
        // Both: the hardware holds the even cut, so it is chosen as at rest and each rank says what is wired.
        let wired = try checkRule("two Macs whose memory a program holds wired, surveyed 173 GB model", both, mimo, checks)
        let wiredLines = ClusterPlacementExplanation.describe(wired, devices: both, layout: mimo)
        checks.require("wired by a program on both: not refused; every rank says stopping the program gives it back",
            wired.refusal == nil && wired.chosen?.cut == 24
                && wiredLines.filter { $0.contains("Rank ") && $0.contains("stopping that program gives it back") }.count == 2
                && !wiredLines.joined(separator: "\n").contains("whatever is freed"))
    }

    // Nothing passes the gate now: the split is still the one the hardware and speed choose, and
    // each rank reports what the gate would say (owner, 2026-10-18: no longer the cut that asks the
    // fewest Macs for memory).
    do {
        // The large Mac admits 87 GiB and the small one 44: no cut of the 173 GB model fits both now.
        let devices = [try SyntheticMac(physicalGiB: 256, freeGiB: 87, inactiveCacheGiB: 60, wiredGiB: 10).device("a"),
                       try SyntheticMac(physicalGiB: 128, freeGiB: 41, inactiveCacheGiB: 47, wiredGiB: 10).device("b")]
        var family = SyntheticFamily(runtimeModelID: "surveyed_mimo_v26_flash", layerCount: 48, admittedCuts: Array(stride(from: 24, through: 44, by: 2)))
        family.generationModes = [.pipeline]; family.stateBytesPerToken = 538
        let wide = try ClusterModelLayoutBuilder.build(family: family,
            tensors: SyntheticFamily.tensors(layerBytes: [Int(0.29 * Double(gib))] + Array(repeating: Int(3.2825 * Double(gib)), count: 47),
                embed: Int(0.60 * Double(gib)), head: Int(0.61 * Double(gib)), largestTensor: gib),
            artifactSHA256: "", configurationSHA256: "")
        let result = try checkRule("87 and 44 GiB admissible, 173 GB model, cuts 24 to 44", devices, wide, checks)
        checks.require("when nothing passes now, the cut chosen at rest is still chosen and the small Mac's rank says what is in its way",
            result.refusal == nil && result.chosen?.cut == 28 && result.chosen?.ranks.first?.device == "a"
                && (result.chosen?.tier ?? 0) > 0 && result.chosen?.ranks.first { $0.device == "b" }?.fit.possible == true
                && result.chosen?.ranks.first { $0.device == "b" }?.fit != .now)
        // The same pair once the large Mac is free: a cut now loads on both, so the split moves to the
        // fastest that does instead of waiting on the small Mac's applications (owner, 2026-10-19).
        let quiet = [try SyntheticMac(physicalGiB: 256, freeGiB: 180, inactiveCacheGiB: 60, wiredGiB: 10).device("a"), devices[1]]
        let later = try checkRule("180 and 44 GiB admissible, 173 GB model, cuts 24 to 44", quiet, wide, checks)
        checks.require("once the large Mac is free the split moves to the fastest cut that loads now on both Macs",
            later.chosen?.tier == 0 && later.chosen?.cuts != result.chosen?.cuts
                && later.chosen?.ranks.allSatisfy { $0.fit == .now } == true)
    }

    // Other programs hold the memory.
    do {
        let full = SyntheticMac(physicalGiB: 128, freeGiB: 2, inactiveCacheGiB: 2, wiredGiB: 6)   // 118 GiB anonymous
        let devices = [try SyntheticMac.idle(256).device("a"), try full.device("b")]
        let result = try checkRule("128 GiB Mac full of other programs, 27B", devices, big, checks)
        checks.require("a full Mac: the plan says applications must release memory, and is not a refusal",
            result.refusal == nil && result.chosen?.tier == 2
                && ClusterPlacementExplanation.describe(result, devices: devices, layout: big).joined().contains("applications would have to release"))
    }
}

/// Speed decides the split when it is known. Arithmetic on constructed rates;
/// the comparison with this pair's measurements is in the evidence folder.
func checkSpeed(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let slow = measured(prefill: 300, decode: 28), fast = measured(prefill: 900, decode: 28)
    let devices = [try SyntheticMac.idle(256).device("slow", speed: slow), try SyntheticMac.idle(128).device("fast", speed: fast)]
    var policy = ClusterPlacementPolicy(); policy.modes = [.pipeline]
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: policy)
    // Balance: x / 300 = (1 - x) / 900 at x = 1/4, which is cut 16 of 64.
    checks.require("a Mac three times as fast at prefill takes three quarters of the layers", result.chosen?.cut == 16 && result.chosen?.ranks.first?.device == "slow")
    let swapped = try ClusterPlacementPlanner.plan(devices: devices.reversed(), layout: big, policy: policy)
    checks.require("the result does not depend on which Mac was named first", swapped.chosen == result.chosen)
    // A leader restriction: only placements whose first range is the named Mac, the rest as before.
    var led = policy; led.leader = "fast"
    let restricted = try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: led)
    checks.require("a leader restriction gives rank 0 to that Mac", restricted.chosen?.ranks.first?.device == "fast")
    checks.require("every alternative under a leader restriction is led by that Mac",
        restricted.alternatives.allSatisfy { $0.ranks.first?.device == "fast" } && !restricted.alternatives.isEmpty)
    checks.require("each Mac alone is still evaluated under a leader restriction", restricted.alone.map(\.device).sorted() == ["fast", "slow"])
    checks.require("a leader restriction never makes the request faster than the free choice",
        (restricted.chosen?.prediction(.rested).requestSeconds ?? 0) >= (result.chosen?.prediction(.rested).requestSeconds ?? .infinity) - 1e-9)
    checks.require("a leader restriction is the same whichever Mac was named first",
        try ClusterPlacementPlanner.plan(devices: devices.reversed(), layout: big, policy: led).chosen == restricted.chosen)
    var stranger = policy; stranger.leader = "neither"
    checks.require("a leader the pair does not have leaves no division, and each Mac alone is still offered",
        try ClusterPlacementPlanner.plan(devices: devices, layout: big, policy: stranger).chosen == nil)
    // Live headroom is not a goal either (owner, 2026-10-18): a Mac with little
    // in reserve at the fastest cut keeps the fastest cut; the gate decides at load.
    do {
        // A fast Mac that admits 8% more than its share needs at the fastest cut.
        let need16 = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [16], mode: .pipeline,
            prefillSchedule: .oneChunkLookahead, layout: big, policy: policy).ranks[1].needBytes
        let tightFast = SyntheticMac(physicalGiB: 128, freeGiB: Double(need16) * 1.08 / Double(gib), inactiveCacheGiB: 0, wiredGiB: 6)
        let pair = [devices[0], try tightFast.device("fast", speed: fast)]
        let tight = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: policy)
        let at16 = try ClusterPlacementPlanner.evaluate(devices: pair, cuts: [16], mode: .pipeline,
            prefillSchedule: .oneChunkLookahead, layout: big, policy: policy)
        checks.require("a cut that fits with under a tenth in reserve is kept: the same cut and order as for the idle pair",
            at16.tier == 0 && at16.smallestHeadroomShare < 0.10 && tight.chosen?.cuts == result.chosen?.cuts
                && tight.chosen?.ranks.map(\.device) == result.chosen?.ranks.map(\.device))
    }
    // What each Mac holds, in one line, with the Mac's own size beside it.
    let holding = result.chosen.map { ClusterPlacementExplanation.holdings($0, devices: devices) } ?? ""
    checks.require("one line says which layers and how many GiB each Mac holds while the session is up",
        holding.hasPrefix("While the session is up: slow holds layers 0 to 15: 3.8") && holding.contains(" GiB of weights of its 256.00 GiB; fast holds layers 16 to 63: 10.2")
            && holding.hasSuffix(" GiB of weights of its 128.00 GiB."))
    // The status view computes the same figure from the layout alone, so it cannot disagree with the plan.
    if let chosen = result.chosen {
        let page = devices[0].profile.memory.pageSizeBytes
        let fromLayout = try ClusterPlacementHoldings.describe(layout: big, labels: chosen.ranks.map(\.device), boundaries: chosen.cuts,
            mode: chosen.mode, pageSizeBytes: page, physicalMemoryBytes: [devices[0].label: devices[0].profile.physicalMemoryBytes],
            localLabel: devices[0].label)
        checks.require("the holdings a status view computes from the layout are the planner's own weights per rank",
            fromLayout.ranks.map(\.weightsBytes) == chosen.ranks.map(\.weightsBytes)
                && fromLayout.ranks.map(\.firstLayer) == chosen.ranks.map(\.firstLayer)
                && fromLayout.line.contains("\(devices[0].label) (this Mac) holds layers") && fromLayout.line.contains("of its 256.00 GiB")
                && !fromLayout.line.contains("of its 128.00 GiB"))
        let split = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [16], mode: .phaseSplit,
            prefillSchedule: .oneChunkLookahead, layout: big, policy: policy)
        let splitHeld = ClusterPlacementHoldings.weightsBytes(layout: big, boundaries: [16], mode: .phaseSplit, pageSizeBytes: page)
        let splitLine = try ClusterPlacementHoldings.describe(layout: big, labels: ["a", "b"], boundaries: [16], mode: .phaseSplit,
            pageSizeBytes: page).line
        checks.require("under a phase split the last rank's holding is every layer, as the planner counts it",
            splitHeld == split.ranks.map(\.weightsBytes) && splitHeld[1] > splitHeld[0]
                && splitLine.contains("b holds layers 16 to 63 and, to decode alone, every earlier layer too"))
        checks.require("holdings refuse a boundary outside the model",
            (try? ClusterPlacementHoldings.describe(layout: big, labels: ["a", "b"], boundaries: [64], mode: .pipeline, pageSizeBytes: page)) == nil)
    }
    // Sustained and rested rates can choose different cuts; both are reported.
    let drifting = measured(prefill: 900, decode: 28, sustainedPrefill: 600)
    let pair = [devices[0], try SyntheticMac.idle(128).device("fast", speed: drifting)]
    var sustainedPolicy = policy; sustainedPolicy.regime = .sustained
    let sustained = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: sustainedPolicy)
    let rested = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: policy)
    checks.require("rested rates are the default and the output says which rates the placement is the best for",
        ClusterPlacementPolicy().regime == .rested && rested.regime == .rested
            && ClusterPlacementExplanation.describe(rested, devices: pair, layout: big).contains { $0.contains("best for rested rates, the default") }
            && ClusterPlacementExplanation.describe(sustained, devices: pair, layout: big).contains { $0.contains("best for sustained rates, as asked") })
    checks.require("the rested rates choose cut 16 and the sustained ones a later cut",
        rested.chosen?.cut == 16 && (sustained.chosen?.cut ?? 0) > 16 && sustained.chosenForOtherRegime?.cut == 16)
    checks.require("a device with no sustained figure is predicted from its rested one, and the prediction says so",
        result.chosen?.sustained.regimeMeasuredOnEveryDevice == false && sustained.chosen?.sustained.regimeMeasuredOnEveryDevice == false
            && rested.chosen?.rested.regimeMeasuredOnEveryDevice == true)
    // Nothing known: the output says speed did not inform the split.
    let unknown = try ClusterPlacementPlanner.plan(devices: [try SyntheticMac.idle(256).device("a"), try SyntheticMac.idle(128).device("b")], layout: big)
    let text = ClusterPlacementExplanation.describe(unknown, devices: devices, layout: big).joined(separator: "\n")
    checks.require("with no measurement the basis is 'assumed equal' and the output says speed did not inform the split",
        unknown.basis.source == .assumedEqual && !unknown.basis.absolute && text.contains("Speed did not inform this split"))
    // The shape of the first-token time with prompt length: one chunk cannot
    // overlap across ranks, so the gain starts with the second chunk.
    do {
        let pair = [try SyntheticMac.idle(256).device("slow", speed: measured(prefill: 300, decode: 28)),
                    try SyntheticMac.idle(128).device("fast", speed: measured(prefill: 780, decode: 27))]
        func first(_ prompt: Int) throws -> (pair: Double, alone: Double, asFast: [String]) {
            var policy = ClusterPlacementPolicy(); policy.modes = [.pipeline]; policy.promptTokens = prompt; policy.regime = .rested
            policy.outputTokens = 128
            let r = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: policy)
            return (r.chosen!.rested.firstTokenSeconds, r.alone.first { $0.device == "fast" }!.rested.firstTokenSeconds, r.aloneAsFast)
        }
        let one = try first(512), two = try first(1024), eight = try first(4096), sixteen = try first(8192)
        checks.require("a one-chunk prompt: the pair's first token is no sooner than the faster Mac's alone, and the result names that Mac",
            one.pair >= one.alone && one.asFast == ["fast"])
        checks.require("a two-chunk prompt: the pair is level with the faster Mac alone (within 10%)", abs(two.pair / two.alone - 1) < 0.10)
        checks.require("the gain appears from the second chunk on and grows with the prompt",
            eight.alone / eight.pair > 1.15 && sixteen.alone / sixteen.pair > eight.alone / eight.pair
                && eight.alone / eight.pair > two.alone / two.pair && eight.asFast.isEmpty && sixteen.asFast.isEmpty)
    }
    // Estimates, most trusted first.
    let a = ClusterSpeedEstimator.Subject(chip: "Chip A", osBuild: "1"), b = ClusterSpeedEstimator.Subject(chip: "Chip B", osBuild: "2")
    func measurement(_ artifact: String, _ subject: ClusterSpeedEstimator.Subject, _ prefill: Double, _ decode: Double) throws -> ClusterSpeedMeasurement {
        try .init(key: .init(artifactSHA256: artifact, chip: subject.chip, osBuild: subject.osBuild, runtimeBinarySHA256: "bin", probe: "p"),
            promptTokens: 8192, chunkTokens: 512, probedLayers: 4, layerCount: 64,
            rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode), sustained: nil,
            measuredUTC: "2026-10-09T00:00:00Z", provenance: "constructed")
    }
    let both = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m", measurements: [try measurement("m", a, 300, 28), try measurement("m", b, 800, 27)])
    checks.require("measured on both: both measured", both.map(\.source) == [.measured, .measured] && both[1].rested.prefillTokensPerSecond == 800)
    let index = [ClusterDeviceIndex(chip: "Chip A", osBuild: "1", benchmark: "x", prefillIndex: 1, decodeIndex: 1),
                 ClusterDeviceIndex(chip: "Chip B", osBuild: "2", benchmark: "x", prefillIndex: 2, decodeIndex: 1)]
    let transferred = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m",
        measurements: [try measurement("m", a, 300, 28), try measurement("other", a, 1000, 60), try measurement("other", b, 2700, 78)], indices: index)
    checks.require("a ratio measured on another model ranks above the model-free index",
        transferred[1].source == .transferredByMeasuredRatio && abs(transferred[1].rested.prefillTokensPerSecond - 810) < 1e-6 && transferred[1].absolute)
    let indexed = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m", measurements: [try measurement("m", a, 300, 28)], indices: index)
    checks.require("with no shared model the model-free index scales the other Mac's measurement",
        indexed[1].source == .transferredByDeviceIndex && indexed[1].rested.prefillTokensPerSecond == 600 && indexed[1].source.isEstimate)
    let nothing = ClusterSpeedEstimator.estimate(devices: [a, b], artifactSHA256: "m", measurements: [])
    checks.require("with nothing measured the devices are assumed equal and nothing is absolute",
        nothing.allSatisfy { $0.source == .assumedEqual && !$0.absolute })
    checks.require("an estimate is labelled wherever it is shown", ClusterPlacementExplanation.speed("b", indexed[1]).contains("ESTIMATE"))
}

/// Budgets follow what was measured, with their margins in words. The rates
/// here are the ones real 27B loads recorded on each Mac.
func checkBudgets(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    func speed(prefill: Double, sustained: Double?, hash: Double, materialize: Double) -> ClusterDeviceSpeed {
        .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: 27),
            sustained: sustained.map { .init(prefillTokensPerSecond: $0, decodeTokensPerSecond: 27) },
            hashBytesPerSecond: hash, materializeBytesPerSecond: materialize, explanation: "constructed from recorded loads")
    }
    let devices = [try SyntheticMac.idle(256).device("a", speed: speed(prefill: 299, sustained: nil, hash: 1.8e9, materialize: 2.45e9)),
                   try SyntheticMac.idle(128).device("b", speed: speed(prefill: 760, sustained: 545, hash: 2.65e9, materialize: 7.5e9))]
    let pipeline = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [16], mode: .pipeline, prefillSchedule: .oneChunkLookahead, layout: big)
    let split = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [16], mode: .phaseSplit, prefillSchedule: .oneChunkLookahead, layout: big)
    let budgets = ClusterPlacementBudgets.derive(candidate: pipeline, devices: devices, layout: big)
    // Recorded: rank 0 on the slower-loading Mac ready in 10.7 s at cut 16.
    checks.require("27B at cut 16: the predicted load of the slowest rank is the 10.7 s real loads recorded, and the budget five times it",
        budgets.map { abs($0.predictedStartupSeconds - 10.7) < 0.6 && $0.slowestRank == 0 && $0.startupSeconds == Int(($0.predictedStartupSeconds * 5).rounded(.up)) } ?? false)
    checks.require("first token: 10 s plus the slower Mac alone with a quarter in hand (4.181 ms per token for 299 tok/s)",
        budgets?.firstTokenBaseMilliseconds == 10_000 && budgets?.firstTokenMicrosecondsPerPromptToken == 4181
            && abs((budgets?.firstTokenSeconds(promptTokens: 8192) ?? 0) - 44.25) < 0.01)
    let splitBudgets = ClusterPlacementBudgets.derive(candidate: split, devices: devices, layout: big)
    checks.require("under a phase split the last rank loads every layer through the loader twice, and the budget follows",
        (splitBudgets?.predictedStartupSeconds ?? 0) > (budgets?.predictedStartupSeconds ?? .infinity) && splitBudgets?.slowestRank == 1)
    checks.require("each budget says its prediction and its margin", budgets?.basis.count == 2
        && (budgets?.basis[0].contains("times 5.0") ?? false) && (budgets?.basis[1].contains("1.25 times") ?? false))
    let unmeasured = [devices[0], try SyntheticMac.idle(128).device("b")]
    checks.require("no budget is derived for a device without measured rates",
        ClusterPlacementBudgets.derive(candidate: try ClusterPlacementPlanner.evaluate(devices: unmeasured, cuts: [16], mode: .pipeline,
            prefillSchedule: .oneChunkLookahead, layout: big), devices: unmeasured, layout: big) == nil)
}

func checkProfiles(_ checks: PlacementChecks) throws {
    let profile = try SyntheticMac.idle(128).profile(chip: "Apple M5 Max")
    let bytes = try profile.encoded()
    checks.require("a profile survives its own encoding and is small", try ClusterDeviceProfile.decode(bytes) == profile && bytes.count < 2048)
    let text = String(decoding: bytes, as: UTF8.self)
    checks.require("a profile has no field for a host name, serial number, address, user or path",
        !["host", "serial", "address", "user", "path", "uuid"].contains { text.lowercased().contains($0) })
    checks.refuses("a profile with a contradicting memory record is refused", because: "contradicts itself") {
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var memory = object["memory"] as! [String: Any]
        memory["admissibleNowBytes"] = (memory["admissibleNowBytes"] as! Int) + 1
        object["memory"] = memory
        _ = try ClusterDeviceProfile.decode(JSONSerialization.data(withJSONObject: object))
    }
    checks.refuses("an oversized profile is refused", because: "larger than") {
        _ = try ClusterDeviceProfile.decode(Data(repeating: 32, count: ClusterDeviceProfile.maximumEncodedBytes + 1))
    }
    checks.refuses("a profile whose chip is not plain text is refused", because: "malformed") {
        _ = try SyntheticMac.idle(64).profile(chip: "bad\nchip")
    }
    // The model-free speed index rides in the profile when asked for, and only this Mac's.
    var indexed = profile
    indexed.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: 2.0e6, decodeIndex: 4.0e4)
    let indexedBytes = try indexed.encoded()
    checks.require("a profile with its speed index survives its own encoding; without one the field is absent",
        try ClusterDeviceProfile.decode(indexedBytes) == indexed && !text.contains("speedIndex")
            && String(decoding: indexedBytes, as: UTF8.self).contains("speedIndex"))
    checks.refuses("a profile carrying another Mac's speed index is refused", because: "another Mac's speed index") {
        var other = profile
        other.speedIndex = .init(chip: "Apple M3 Ultra", osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 2.0e6, decodeIndex: 4.0e4)
        _ = try ClusterDeviceProfile.decode(other.encoded())
    }
    checks.refuses("a speed index that is not a finite positive rate is refused", because: "Device index is malformed") {
        var bad = profile
        bad.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 0, decodeIndex: 4.0e4)
        _ = try ClusterDeviceProfile.decode(bad.encoded())
    }
}

/// A placement is planned for the requested context, and the split is chosen
/// from hardware and measured speed alone (owner, 2026-10-18): the same Macs
/// get the same split whether one of them is idle or busy with applications.
func checkRequestedContext(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    // Mac B 15 % faster at prefill, so the fastest cut gives it more layers.
    func speed(_ prefill: Double) -> ClusterDeviceSpeed {
        .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: 27),
            sustained: nil, hashBytesPerSecond: 2e9, materializeBytesPerSecond: 4e9, explanation: "constructed")
    }
    let a = try SyntheticMac.idle(256).device("a", speed: speed(1000))
    let idle = try SyntheticMac.idle(128).device("b", speed: speed(1150))
    // The same Mac with desktop applications holding most of its memory, too much for its share now.
    let busy = try SyntheticMac(physicalGiB: 128, freeGiB: 10, inactiveCacheGiB: 4).device("b", speed: speed(1150))
    var policy = ClusterPlacementPolicy()
    policy.leader = "a"; policy.promptTokens = 20_480; policy.outputTokens = 128; policy.modes = [.pipeline]
    var refused = false
    do { _ = try ClusterPlacementPlanner.plan(devices: [a, busy], layout: big, policy: policy) } catch { refused = true }
    checks.require("requested context: a 20,480-token request beyond the layout's planned one needs the family's charge", refused)
    // The family's every-rank charge grows with the context (KV of every attention layer).
    policy.largestContextTokens = 32_768
    policy.requestChargeEveryRankBytes = big.requestChargeEveryRankBytes * 20_608 / big.maximumContextTokens
    let atRest = try ClusterPlacementPlanner.plan(devices: [a, idle], layout: big, policy: policy)
    let whileBusy = try ClusterPlacementPlanner.plan(devices: [a, busy], layout: big, policy: policy)
    let reservation = try ClusterPlacementPlanner.evaluate(devices: [a, busy], cuts: [32], mode: .pipeline,
        prefillSchedule: .oneChunkLookahead, layout: big)
    let atContext = try ClusterPlacementPlanner.evaluate(devices: [a, busy], cuts: [32], mode: .pipeline,
        prefillSchedule: .oneChunkLookahead, layout: big, policy: policy)
    checks.require("requested context: a rank's request need is priced at the requested context",
        atContext.ranks[1].requestNeedBytes > reservation.ranks[1].requestNeedBytes)
    func share(_ c: ClusterPlacementCandidate?, _ label: String) -> Int {
        c?.ranks.first { $0.device == label }.map { $0.endLayer - $0.firstLayer } ?? -1
    }
    checks.require("requested context: the fastest placement gives the faster Mac more layers",
        share(atRest.chosen, "b") > share(atRest.chosen, "a"))
    checks.require("requested context: live memory does not move the split",
        atRest.chosen?.cuts == whileBusy.chosen?.cuts && atRest.chosen?.mode == whileBusy.chosen?.mode
            && atRest.chosen?.ranks.map(\.device) == whileBusy.chosen?.ranks.map(\.device))
    checks.require("requested context: the busy Mac's live memory is still reported",
        atRest.chosen?.tier == 0 && (whileBusy.chosen?.tier ?? 0) > 0
            && whileBusy.chosen?.ranks.first { $0.device == "b" }?.fit != .now && whileBusy.chosen?.ranks.first { $0.device == "b" }?.hardwareFits == true)
}

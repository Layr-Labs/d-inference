import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Gemma 4 26B's tensor-parallel facts and the fastest-plan rule
/// (`ClusterTensorParallelChoice.fastest`, owner policy 2026-11-01): the
/// layouts built from the retained real headers carry the plan, its exact
/// per-rank bytes and the routing prior; under the provider's
/// tensor-parallel-first policy a Gemma pair is placed in tensor parallel only
/// where the planner predicts it faster than the pipeline. Constructed Macs,
/// recorded headers and links: no model, no GPU, no network.
func checkGemmaTensorParallel(golden: URL, _ checks: PlacementChecks) throws {
    let inputs = golden.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StageMetadataChecks/Inputs", isDirectory: true)
    let configuration = try Data(contentsOf: inputs.appendingPathComponent("config.json"))
    let manifest = try Data(contentsOf: inputs.appendingPathComponent("manifest.json"))
    let tensors = try gemmaRetainedTensors(inputs)
    let layout = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors, manifest: manifest)
    try checkGemmaLayouts(layout, configuration: configuration, tensors: tensors, golden: golden, checks)
    let priced = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors, manifest: manifest,
        tensorParallelAllocationBound: { $0 + 16_384 })
    try checkGemmaRequestAllowance(priced, checks)
    try checkGemmaLaneWidths(priced, unpriced: layout, checks)
    try checkGemmaFastestPlan(priced, checks)
    try checkGemmaPairModePrediction(golden: golden, checks)
}

/// Every stored tensor of the QAT 4-bit artifact, as its retained headers name it.
private func gemmaRetainedTensors(_ inputs: URL) throws -> [ClusterPlacementStoredTensor] {
    var tensors: [ClusterPlacementStoredTensor] = []
    for index in 1...3 {
        let header = try JSONSerialization.jsonObject(with: Data(contentsOf: inputs.appendingPathComponent(
            "model-0000\(index)-of-00003.safetensors.header.json"))) as? [String: Any] ?? [:]
        for (name, value) in header where name != "__metadata__" {
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int], let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2, offsets[1] > offsets[0] else {
                throw ProbeError("Malformed retained Gemma header entry: \(name)")
            }
            tensors.append(.init(name: name, byteCount: offsets[1] - offsets[0], dtype: dtype, shape: shape))
        }
    }
    return tensors
}

/// What one rank holds of a layout's tensor-parallel facts: every part's
/// replicated bytes and half its divided bytes.
private func gemmaRankBytes(_ layout: ClusterModelLayout) -> Int {
    guard let tp = layout.tensorParallel else { return 0 }
    let parts = Array(zip(tp.layerDividedBytes, tp.layerReplicatedBytes))
        + [(tp.ingressDividedBytes, tp.ingressReplicatedBytes), (tp.egressDividedBytes, tp.egressReplicatedBytes)]
    return parts.reduce(0) { $0 + $1.1 + ($1.0 + 1) / 2 }
}

private func checkGemmaLayouts(_ layout: ClusterModelLayout, configuration: Data, tensors: [ClusterPlacementStoredTensor],
                               golden: URL, _ checks: PlacementChecks) throws {
    let expected = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/gemma-4-26b-qat-4bit.json")))
    checks.require("Gemma QAT 4-bit: the layout from the retained real headers equals its golden layout, tensor-parallel facts included",
        layout == expected)
    let family = layout.tensorParallel?.family
    checks.require("Gemma: tensor parallel is listed, planned as gemma4_heads_and_expert_channels_v1 on two ranks, chosen only where faster",
        layout.generationModes == [.pipeline, .tensorParallel] && family?.plan == "gemma4_heads_and_expert_channels_v1"
            && family?.ranks == [2] && family?.choice == .fastest)
    checks.require("Gemma: two reductions a layer and one a step; 101,376 bytes a token in the packed feed-forward sum, 112,640 a layer; own heads' state",
        family?.reductionsPerLayer == 2 && family?.reductionsPerStep == 1 && family?.partialBytesPerToken == 101_376
            && family?.layerPartialBytesPerToken == 112_640 && family?.stateDividesByHeads == true
            && layout.tensorParallel?.reductionsPerStep(layerCount: layout.layerCount) == 61)
    // The plan check (TensorParallelPlanChecks/gemma-run.sh) cuts every tensor's local shape: 8,040,450,108 bytes a rank.
    checks.require("Gemma QAT 4-bit: a rank's share is exactly the plan's cut, 8,040,450,108 bytes (overlap groups and zero rows included, the tied embedding once)",
        gemmaRankBytes(layout) == 8_040_450_108)
    checks.require("Gemma QAT 4-bit: 8 of 128 experts over 12,846,366,720 bytes, 11,678,515,200 of them divided; a decode step reads 2,424,219,708 bytes",
        layout.routedExperts?.routing == ClusterExpertRouting(selected: 8, experts: 128)
            && layout.routedExperts?.loadedBytes == 12_846_366_720 && layout.routedExperts?.tensorParallelDividedBytes == 11_678_515_200
            && ClusterHardwarePrior.decodeBytesPerToken(layout) == 2_424_219_708)
    // The 8-bit artifact (two catalog entries): its tensors are the 4-bit headers' at 8 bits (`expectedShape`), whose
    // per-layer bytes must equal the layouts recorded on both Macs from its real headers; its facts are spliced into them.
    var root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] ?? [:]
    for key in ["quantization", "quantization_config"] {
        var table = root[key] as? [String: Any] ?? [:]
        table["bits"] = 8; root[key] = table
    }
    let plan = try Gemma4TensorParallelPlan(configuration: root)
    let text = try tensors.filter { $0.name.hasPrefix(Gemma4PlacementFamily.textPrefix) }.map { tensor in
        let shape = try plan.expectedShape(key: tensor.name)
        return ClusterPlacementStoredTensor(name: tensor.name, byteCount: shape.reduce(tensor.dtype == "U32" ? 4 : 2, *),
            dtype: tensor.dtype, shape: shape)
    }
    let decoded = try Gemma4StageGeometry.decode(JSONSerialization.data(withJSONObject: root), defaultQuantizationBits: 8)
    for (name, model) in [("gemma-4-26b-8bit", Gemma4RegisteredModel.twentySixB8Bit), ("gemma-4-26b", .twentySixB)] {
        let row = try Gemma4RegisteredSpecification.registered(model)
        let built = try ClusterModelLayoutBuilder.build(family: Gemma4PlacementFamily(specification: row, decoded: decoded),
            tensors: text, artifactSHA256: row.artifactSHA256, configurationSHA256: row.configurationSHA256)
        let recorded = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/\(name).json")))
        var a = try JSONSerialization.jsonObject(with: built.encoded()) as? [String: Any] ?? [:]
        var b = try JSONSerialization.jsonObject(with: recorded.encoded()) as? [String: Any] ?? [:]
        a["excluded"] = nil; b["excluded"] = nil  // the vision tower, which no rank loads
        checks.require("\(name): the layout from the 8-bit shapes equals its golden layout (vision tower aside), tensor-parallel facts included",
            NSDictionary(dictionary: a).isEqual(to: b))
        checks.require("\(name): a rank's share is exactly the plan's cut, 14,915,635,260 bytes; 8 of 128 experts over 24,265,359,360 bytes",
            gemmaRankBytes(recorded) == 14_915_635_260 && recorded.routedExperts?.loadedBytes == 24_265_359_360
                && recorded.tensorParallel?.family.choice == .fastest)
    }
}

/// A product layout carries the rank's native reserve (`Gemma4TensorParallelRequestBudget`):
/// its own heads' state and prompt-prefix capture, the activation floor, the freed-buffer cache
/// and eight sealed frames. The prefix memory tier is not charged (its budget is measured room).
private func checkGemmaRequestAllowance(_ priced: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let allowance = priced.tensorParallel?.family.requestAllowance
    let budget = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512, promptTokens: 32_768,
        allocationBound: { $0 + 16_384 })
    checks.require("Gemma TP allowance: the layout quotes the rank's budget at the profile's longest request (65,536 tokens, 512-token chunks)",
        allowance == budget.allowance && allowance?.maximumContextTokens == 65_536 && allowance?.maximumChunkTokens == 512)
    checks.require("Gemma TP allowance: the conservative 5.5 GiB activation floor and the freed-buffer cache are charged once beside the request",
        budget.rankBytes == Gemma4TensorParallelRequestBudget.activationFloorBytes + Gemma4TensorParallelRequestBudget.freedBufferCacheBytes
            + budget.allowance.collectiveScratchBytes && Gemma4TensorParallelRequestBudget.activationFloorBytes == 5_905_580_032
            && budget.allowance.reservedBytes == budget.requestBytes + budget.rankBytes)
    // A 32,768-token prompt's own full rows (5 layers x 1 head x 512 x K and V, bf16) and a 1,024-token window
    // of each of the 25 sliding layers (4 heads x 256 x K and V), each array at the allocator's bound.
    let capture = 10 * (32_768 * 512 * 2 + 16_384) + 50 * (1_024 * 4 * 256 * 2 + 16_384)
    checks.require("Gemma TP allowance: the request's own prompt-prefix capture (\(budget.prefixCaptureBytes) bytes), and nothing for the memory tier",
        budget.prefixCaptureBytes == capture
            && budget.requestBytes == budget.stateBytes + budget.transientBytes + budget.partialBytes + budget.logitsBytes + capture)
    let off = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512, promptTokens: 32_768,
        keepsPrefixes: false, allocationBound: { $0 + 16_384 })
    checks.require("Gemma TP allowance: a rank whose prefix cache is off charges no capture; the capture is the quote's only prefix term",
        off.prefixCaptureBytes == 0 && off.rankBytes == budget.rankBytes
            && budget.allowance.reservedBytes - off.allowance.reservedBytes == capture)
    checks.require("Gemma TP allowance: eight sealed frames of the packed feed-forward collective (512 x 101,376 bytes and the seal)",
        budget.allowance.maximumCollectivePayloadBytes == 512 * 101_376
            && budget.allowance.collectiveScratchBytes == 8 * (budget.allowance.maximumCollectiveFrameBytes + 16_384))
    // A lane after the first is one more request's whole charge (`reserveLane`): the layout states it, so the planner
    // prices a saved width as the rank's LOAD reserves it. Read from the layout's own bytes, as the provider reads them.
    let family = try JSONSerialization.jsonObject(with: JSONEncoder().encode(priced.tensorParallel?.family)) as? [String: Any]
    checks.require("Gemma TP lane charge: the layout states each further lane's charge, the request's whole charge (\(budget.requestBytes) bytes)",
        (family?["laneBytes"] as? Int) == budget.requestBytes)
    let whole = try Gemma4StateBudget.estimate(maximumTokens: 8_320, chunkSize: 512)
    let own = try Gemma4StateBudget.estimate(maximumTokens: 8_320, chunkSize: 512, ranks: 2)
    checks.require("Gemma TP state: a rank keeps its own KV heads (\(own.stateAndBoundaryBytes) of the whole model's \(whole.stateAndBoundaryBytes) bytes at 8,320 tokens)",
        whole.stateAndBoundaryBytes == 719_380_600 && own.fullKVBytes * 2 == whole.fullKVBytes && own.ringKVBytes * 2 == whole.ringKVBytes
            && own.boundaryBytes == whole.boundaryBytes && own.stateAndBoundaryBytes < whole.stateAndBoundaryBytes)
    // The planner quotes a rank at its exact shard plus that reserve.
    let devices = try [SyntheticMac.idle(256).device("a"), SyntheticMac.idle(256).device("b")]
    var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
    let rank = try ClusterPlacementPlanner.plan(devices: devices, layout: priced, policy: forced).chosen?.ranks.first
    let pages = (priced.layers.reduce(0) { $0 + $1.weights.tensorCount } + priced.ingress.tensorCount + priced.egress.tensorCount) * SyntheticMac.page
    checks.require("Gemma TP quote: a rank's weights are its exact 8,040,450,108-byte shard in whole pages, and its request need covers the reserve",
        rank?.weightsBytes == 8_040_450_108 + pages && (rank?.requestNeedBytes ?? 0) >= budget.allowance.reservedBytes)
    // Two idle 24 GB Macs (the fastest-plan checks' M4 Pro) hold a rank each with that quote, the request's capture in it.
    let small = try [SyntheticMac.idle(24).device("a"), SyntheticMac.idle(24).device("b")]
    let fitted = try ClusterPlacementPlanner.plan(devices: small, layout: priced, policy: forced).chosen?.ranks ?? []
    let spare = fitted.map { $0.admissibleNowBytes - $0.needBytes }.min() ?? -1
    checks.require("Gemma TP quote: two 24 GB Macs each fit a rank now, its request's prompt-prefix capture charged (\(spare) bytes to spare)",
        fitted.count == 2 && fitted.allSatisfy { $0.fit == .now && $0.requestNeedBytes >= budget.allowance.reservedBytes } && spare >= 0)
}

/// A saved width is priced as the rank's LOAD reserves it (`Gemma4TensorParallelRequestBudget.reservedBytes(lanes:)`):
/// each lane after the first adds the layout's lane charge to every rank's request need, so two idle 256 GB Macs hold
/// eight lanes and two idle 24 GB Macs fewer. A layout that states no lane charge prices no width, and one whose lane
/// charge is nothing or more than its allowance's request part is refused.
private func checkGemmaLaneWidths(_ priced: ClusterModelLayout, unpriced: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let budget = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512, promptTokens: 32_768,
        allocationBound: { $0 + 16_384 })
    var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
    func ranks(_ macs: [ClusterPlacementDevice], lanes: Int?) throws -> [ClusterPlacementRank] {
        var policy = forced; policy.tensorParallelLanes = lanes
        return try ClusterPlacementPlanner.plan(devices: macs, layout: priced, policy: policy).chosen?.ranks ?? []
    }
    let big = try [SyntheticMac.idle(256).device("a"), SyntheticMac.idle(256).device("b")]
    let one = try ranks(big, lanes: nil)
    // One lane reserves the allowance alone, as LOAD did before widths; the prefix tier's room is measured beside the
    // same figure at every width: every lane's request and the rank's reserve once.
    checks.require("Gemma TP width 1: LOAD reserves the allowance alone, and the planner prices one lane as no width",
        try budget.reservedBytes(lanes: 1) == budget.allowance.reservedBytes && one == (try ranks(big, lanes: 1)))
    for lanes in [2, 4, 6, 8] {
        let reserved = try budget.reservedBytes(lanes: lanes), sized = try ranks(big, lanes: lanes)
        checks.require("Gemma TP width \(lanes): LOAD reserves the allowance and \(lanes - 1) more lane charges (\(reserved) bytes), "
            + "every lane's request and the rank's reserve once, and each rank's request need grows by exactly those charges",
            reserved == budget.allowance.reservedBytes + (lanes - 1) * budget.laneBytes
                && reserved == lanes * budget.requestBytes + budget.rankBytes && sized.count == 2 && one.count == 2
                && zip(sized, one).allSatisfy { $0.requestNeedBytes - $1.requestNeedBytes == (lanes - 1) * budget.laneBytes })
    }
    checks.require("Gemma TP width: LOAD and the planner refuse no lanes and more than the protocol's eight",
        [0, 9].allSatisfy { (try? budget.reservedBytes(lanes: $0)) == nil && (try? ranks(big, lanes: $0)) == nil })
    // The layout's lane charge is bounded where it is read: one more request beside the allowance, never nothing and
    // never more than the allowance's request part.
    func stating(_ lane: Int) throws -> ClusterModelLayout {
        var object = try JSONSerialization.jsonObject(with: priced.encoded()) as? [String: Any] ?? [:]
        var tensor = object["tensorParallel"] as? [String: Any] ?? [:], family = tensor["family"] as? [String: Any] ?? [:]
        family["laneBytes"] = lane; tensor["family"] = family; object["tensorParallel"] = tensor
        return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    }
    let requestPart = budget.allowance.requestBytesExcludingCollectives
    checks.require("Gemma TP lane charge: the layout's own is read back; nothing, or more than its allowance's request part, is refused",
        (try? stating(budget.laneBytes))?.tensorParallel?.family.laneBytes == budget.laneBytes
            && (try? stating(0)) == nil && (try? stating(requestPart + 1)) == nil)
    // A forced tensor-parallel width that fits no Mac is refused, not placed: that width does not fit.
    func widest(_ macs: [ClusterPlacementDevice]) -> Int {
        [8, 6, 4, 2].first { lanes in
            let sized = (try? ranks(macs, lanes: lanes)) ?? []
            return sized.count == 2 && sized.allSatisfy { $0.fit == .now }
        } ?? 1
    }
    let small = try [SyntheticMac.idle(24).device("a"), SyntheticMac.idle(24).device("b")]
    let smallWidest = widest(small)
    checks.require("Gemma TP width: two idle 256 GB Macs hold eight lanes now, two idle 24 GB Macs \(smallWidest)",
        widest(big) == 8 && smallWidest < 8)
    var unpricedWidth = forced; unpricedWidth.tensorParallelLanes = 4
    checks.require("Gemma TP width: a layout that states no lane charge (metadata only) prices no width",
        (try? ClusterPlacementPlanner.plan(devices: big, layout: unpriced, policy: unpricedWidth)) == nil
            && unpriced.tensorParallel?.family.laneBytes == nil && priced.tensorParallel?.family.laneBytes == budget.laneBytes)
}

/// The fastest-plan rule on constructed pairs, under the provider's own
/// first-placement policy (`ClusterPlacementFlow.decide`: tensor parallel
/// first, an unmeasured link assumed): the M5 Ultra pair keeps the pipeline
/// with default link costs; where tensor parallel is predicted faster on the
/// device-index prior alone (small Macs, measured links) the pipeline is kept
/// until each Mac's share step is measured; a share probe or requests served
/// in tensor parallel then decide.
private func checkGemmaFastestPlan(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    // Each Mac's measured whole-model rates and device index (`qmm_h4096_b4_g64_x16_v1`). M5 Ultra: Gemma QAT 4-bit's
    // production median (90 tok/s) and about 7,000 prefill tok/s at 8K; M4 Pro: the solo pair rows of 2026-09-20
    // (47 / 371). Indices: the M5 Ultra's measured one; the M4 Pro's scaled from the M4 Max's by bandwidth. Inputs only.
    func mac(_ label: String, _ gib: Double, chip: String, decode: Double, prefill: Double, index: (Double, Double)) throws -> ClusterPlacementDevice {
        var profile = try SyntheticMac.idle(gib).profile(chip: chip)
        profile.speedIndex = .init(chip: chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: index.1, decodeIndex: index.0)
        return .init(label: label, profile: profile, speed: measured(prefill: prefill, decode: decode))
    }
    let ultras = try ["a", "b"].map { try mac($0, 256, chip: "Apple M5 Ultra", decode: 90, prefill: 7_000, index: (46_409, 2_337_768)) }
    func pros(_ gib: Double) throws -> [ClusterPlacementDevice] {
        try ["a", "b"].map { try mac($0, gib, chip: "Apple M4 Pro", decode: 47, prefill: 371, index: (10_550, 260_000)) }
    }
    // The pair's own probe (two M5 Ultra, keyed JACCL, 2026-10-31): sealed all-sum 29 us at 16 KB, 3,919 us at 32 MiB.
    func probe(allSum: Int, large: Int) -> ClusterLinkCosts {
        ClusterLinkCosts(probe: ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
            pointToPointSmallMicroseconds: 180, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 2_502,
            allSumSmallBytes: 16_384, allSumSmallMicroseconds: allSum, allSumLargeBytes: 32 << 20, allSumLargeMicroseconds: large),
            measuredUTC: "2026-10-31T00:00:00Z")!
    }
    let measuredLink = probe(allSum: 29, large: 3_919), fastLink = probe(allSum: 5, large: 1_000), slowLink = probe(allSum: 109, large: 9_000)
    func first(_ prompt: Int, _ outputs: Int) -> ClusterPlacementPolicy {
        var p = ClusterPlacementPolicy(); p.promptTokens = prompt; p.outputTokens = outputs
        p.tensorParallelFirst = true; p.tensorParallelAssumesUnmeasuredLink = true
        return p
    }
    func plan(_ devices: [ClusterPlacementDevice], _ policy: ClusterPlacementPolicy, _ link: ClusterLinkCosts) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
    }
    func tensor(_ r: ClusterPlacementResult) -> Bool { r.chosen?.mode == .tensorParallel && r.tensorParallel?.verdict == .chosen }
    func pipeline(_ r: ClusterPlacementResult) -> Bool { r.chosen?.mode == .pipeline && r.tensorParallel?.verdict == .predictedSlower }
    func predicted(_ r: ClusterPlacementResult) -> (tensor: Double, other: Double) {
        (r.tensorParallel?.tensorParallel?.prediction(.rested).requestSeconds ?? .infinity, r.tensorParallel?.bestOtherSeconds ?? .infinity)
    }
    // Predicted faster by the margin on the device-index prior alone: the pipeline is kept (the evidence rule).
    func held(_ r: ClusterPlacementResult) -> Bool {
        r.chosen?.mode == .pipeline && r.tensorParallel?.verdict == .predictedFasterOnPriorOnly && r.tensorParallel?.evidence == .priorOnly
            && predicted(r).tensor < predicted(r).other * 0.95
    }
    func times(_ r: ClusterPlacementResult) -> String { String(format: "%.3f s vs %.3f s", predicted(r).tensor, predicted(r).other) }
    func reason(_ r: ClusterPlacementResult) -> String { ClusterPlacementExplanation.deploymentReason(r) ?? "" }

    // 1. Two M5 Ultra 256 GB, default link costs: a pipeline for every request, prompt-heavy to decode-heavy.
    for (prompt, outputs) in [(8_192, 128), (1_024, 128), (128, 128)] {
        let result = try plan(ultras, first(prompt, outputs), .unmeasured)
        checks.require("Gemma fastest plan: 2x M5 Ultra 256 GB, default link costs, \(prompt) + \(outputs): a pipeline, tensor parallel predicted slower on the assumed link",
            pipeline(result) && result.tensorParallel?.reductionKeyed == true && !result.basis.linkCostsMeasured
                && (ClusterPlacementExplanation.deploymentReason(result) ?? "").hasPrefix("Pipeline: tensor parallel is predicted slower"))
    }
    // A fresh pair (index ratios only, nothing measured) predicts no gain from a share: a pipeline too.
    let fresh = ultras.map { device -> ClusterPlacementDevice in
        .init(label: device.label, profile: device.profile, speed: .assumedEqual)
    }
    checks.require("Gemma fastest plan: 2x M5 Ultra, nothing measured: a pipeline", pipeline(try plan(fresh, first(128, 128), .unmeasured)))
    // The choice alone holds it back: the same layout without it (a TP-first family) is placed in tensor parallel.
    let ruled = try ClusterPlacementPlanner.plan(devices: ultras, layout: try gemmaTensorParallelFirst(layout),
        policy: first(8_192, 128), link: .unmeasured)
    checks.require("Gemma fastest plan: without its choice the same layout, Macs and policy put tensor parallel first",
        ruled.chosen?.mode == .tensorParallel)
    // Tensor parallel prefills serially, the only schedule a tensor-parallel runtime admits; the pipeline keeps the
    // lookahead (2026-11-03: a Gemma or MiMo pair planned in tensor parallel was saved with the lookahead and refused at load).
    let piped = try plan(ultras, first(8_192, 128), .unmeasured)
    checks.require("Gemma: a plan in tensor parallel prefills serially, a pipeline with the lookahead",
        ruled.chosen?.prefillSchedule == .serial && piped.chosen?.mode == .pipeline && piped.chosen?.prefillSchedule == .oneChunkLookahead
            && layout.prefillSchedules.contains(.oneChunkLookahead))

    // 2. Two small Macs (24 and 32 GB M4 Pro), default link costs: tensor parallel is predicted faster for a
    // decode-heavy request, but on the device-index prior alone, so the pipeline is kept until it is measured.
    for gib in [24.0, 32.0] {
        let small = try pros(gib)
        let decodeHeavy = try plan(small, first(128, 128), .unmeasured)
        checks.require("Gemma fastest plan: 2x M4 Pro \(Int(gib)) GB, default link costs, 128 + 128: tensor parallel predicted faster by the margin on the prior only (\(times(decodeHeavy))), so the pipeline is kept",
            held(decodeHeavy) && decodeHeavy.tensorParallel?.tensorParallel?.ranks.allSatisfy({ $0.fit == .now }) == true
                && decodeHeavy.tensorParallel?.tensorParallel?.prefillSchedule == .serial)
        checks.require("Gemma fastest plan: 2x M4 Pro \(Int(gib)) GB, default link costs, 8,192 + 128: a pipeline (the prompt's sums dominate)",
            pipeline(try plan(small, first(8_192, 128), .unmeasured)))
    }
    // Measured half steps of 12 ms (`gemma-tp-plan.md` §3.7 infers 1.5-1.7x for such Macs): tensor parallel.
    let smallProbed = try plan(withShareProbes(try pros(32), layout: layout, halfStepMicroseconds: 12_000), first(128, 128), .unmeasured)
    checks.require("Gemma evidence rule: 2x M4 Pro 32 GB, default link costs, 128 + 128, both Macs' share probes at 12 ms a half step: tensor parallel on the measured split (\(times(smallProbed)))",
        tensor(smallProbed) && smallProbed.tensorParallel?.evidence == .measured)

    // 3. A measured link moves the prediction both ways; on the prior alone it never chooses tensor parallel.
    let ultraDefault = try plan(ultras, first(1_024, 128), .unmeasured), ultraMeasured = try plan(ultras, first(1_024, 128), measuredLink)
    checks.require("Gemma fastest plan: 2x M5 Ultra, 1,024 + 128: a pipeline on default costs and on the pair's measured 29 us link",
        pipeline(ultraDefault) && pipeline(ultraMeasured))
    let fast = try plan(ultras, first(1_024, 128), fastLink)
    checks.require("Gemma fastest plan: 2x M5 Ultra, 1,024 + 128, a measured 5 us link, no share probe: tensor parallel predicted faster on the prior only (\(times(fast))), so the pipeline is kept, and the line says the predicted gain",
        held(fast) && reason(fast).hasPrefix("Pipeline: tensor parallel is predicted"))
    // Without a share probe the device index credits about half of the M5 Ultra's 11.1 ms step to weights (a rank
    // halves it); `mainnet/gemma-tp-plan.md` §3.2 infers 1.4-2.0 ms. So a decode-heavy request on the measured link is
    // predicted about 6% faster in tensor parallel on the prior, and the pipeline is kept until a measurement says so.
    let ultraShort = try plan(ultras, first(128, 128), measuredLink), short = predicted(ultraShort)
    checks.require("Gemma evidence rule: 2x M5 Ultra 256 GB, the measured 29 us link, 128 + 128, no share probe or served record: tensor parallel predicted faster on the device-index prior only (\(times(ultraShort))), so the pipeline is kept",
        held(ultraShort) && short.tensor > short.other * 0.85)
    checks.require("Gemma evidence rule: its plan line says the predicted gain, that it comes from the device index, and what measures it (\(reason(ultraShort)))",
        reason(ultraShort).hasPrefix("Pipeline: tensor parallel is predicted 6% faster for requests of 128 prompt and 128 answer tokens (")
            && reason(ultraShort).contains(", but from the device index, not its own measured step; it can be chosen once its step is measured on both Macs")
            && ClusterPlacementExplanation.tensorParallelNote(ultraShort) == .notMeasuredYet
            && ultraShort.shards?.options.first { $0.kind == .tensorParallel }?.verdict == .predictedFasterOnPriorOnly)
    // A share probe of this model on both Macs (a tensor-parallel load records one): the measured split decides. 10.3 ms
    // is the plan's half step (11.1 ms less the 0.7-1.0 ms a rank's weights save, plus its own kernels); 7.0 ms a fast one.
    let planHalf = try plan(withShareProbes(ultras, layout: layout, halfStepMicroseconds: 10_300), first(128, 128), measuredLink)
    let fastHalf = withShareProbes(ultras, layout: layout, halfStepMicroseconds: 7_000)
    let probedFast = try plan(fastHalf, first(128, 128), measuredLink)
    checks.require("Gemma evidence rule: 2x M5 Ultra, 29 us, 128 + 128, both Macs' share probes at 10.3 ms a half step: a pipeline, tensor parallel predicted slower on the measured split (\(times(planHalf)))",
        pipeline(planHalf) && planHalf.tensorParallel?.evidence == .measured)
    checks.require("Gemma evidence rule: the same with share probes at 7.0 ms a half step: tensor parallel on the measured split (\(times(probedFast))), and its line says so (\(reason(probedFast)))",
        tensor(probedFast) && probedFast.tensorParallel?.evidence == .measured
            && reason(probedFast).hasPrefix("Tensor parallel: predicted") && reason(probedFast).hasSuffix(", on its own step as measured on both Macs."))
    let oneMac = try plan(withShareProbes(ultras, layout: layout, halfStepMicroseconds: 7_000, members: ["a"]), first(128, 128), measuredLink)
    let otherModel = try plan(withShareProbes(ultras, layout: layout, halfStepMicroseconds: 7_000, artifact: String(repeating: "f", count: 64)),
        first(128, 128), measuredLink)
    checks.require("Gemma evidence rule: a share probe on one Mac only, or another model's on both, is no evidence: the pipeline is kept",
        held(oneMac) && held(otherModel))
    // Requests this build served in tensor parallel: the shard rates they corrected decide (the pipeline predicts 87 tok/s).
    let servedSlow = try plan(try afterServedTensorParallel(ultras, layout: layout, link: measuredLink, decode: 80, prompt: 128, outputs: 128),
        first(128, 128), measuredLink)
    let servedFast = try plan(try afterServedTensorParallel(ultras, layout: layout, link: measuredLink, decode: 110, prompt: 128, outputs: 128),
        first(128, 128), measuredLink)
    checks.require("Gemma evidence rule: 2x M5 Ultra, 29 us, 128 + 128, served in tensor parallel at 80 tok/s: a pipeline on the served split (\(times(servedSlow)))",
        pipeline(servedSlow) && servedSlow.tensorParallel?.evidence == .measured)
    checks.require("Gemma evidence rule: the same served at 110 tok/s: tensor parallel on the served split (\(times(servedFast)))",
        tensor(servedFast) && servedFast.tensorParallel?.evidence == .measured)
    // The rule is the fastest-plan family's alone: without its choice, the plain comparison takes the prior's gain.
    var comparison = ClusterPlacementPolicy(); comparison.promptTokens = 128; comparison.outputTokens = 128
    let unruled = try ClusterPlacementPlanner.plan(devices: ultras, layout: try gemmaTensorParallelFirst(layout), policy: comparison,
        link: measuredLink)
    checks.require("Gemma evidence rule: the same layout without its choice, compared plainly on the same Macs and link, still takes tensor parallel on the prior, and states no evidence",
        unruled.chosen?.mode == .tensorParallel && unruled.tensorParallel?.verdict == .chosen && unruled.tensorParallel?.evidence == nil)
    let small = try pros(32)
    let smallDefault = try plan(small, first(1_024, 128), .unmeasured)
    let smallMeasured = try plan(small, first(1_024, 128), measuredLink), smallSlow = try plan(small, first(1_024, 128), slowLink)
    checks.require("Gemma fastest plan: 2x M4 Pro 32 GB, 1,024 + 128: a pipeline on default costs, tensor parallel predicted faster on the measured 29 us link but on the prior only (\(times(smallMeasured))), a pipeline on a measured 109 us one",
        pipeline(smallDefault) && held(smallMeasured) && pipeline(smallSlow))
    // An automatic replacement invents no link: without a measured one, the pipeline it runs.
    var replacement = first(128, 128); replacement.tensorParallelAssumesUnmeasuredLink = false
    let kept = try plan(small, replacement, .unmeasured)
    checks.require("Gemma fastest plan: an automatic replacement before any measured link keeps a pipeline (tensor parallel not predicted)",
        kept.chosen?.mode == .pipeline && kept.tensorParallel?.verdict == .reductionNotMeasured)
    // A pipeline the pair keeps holds a measured tensor-parallel win back under the margin it must beat, as for any mode;
    // and the mode a pair served before an update is kept over the rule, as it is kept over any prediction.
    var keep = first(128, 128); keep.keptMode = .pipeline; keep.keptModeMargin = .infinity; keep.keptModeReason = "kept after the update"
    let keptPipeline = try plan(fastHalf, keep, measuredLink)
    checks.require("Gemma fastest plan: a kept pipeline holds tensor parallel back even on measured share steps (unlike a TP-first family)",
        keptPipeline.chosen?.mode == .pipeline && keptPipeline.keptModeReason == "kept after the update")
    keep.keptMode = .tensorParallel
    let keptTensor = try plan(ultras, keep, measuredLink)
    checks.require("Gemma evidence rule: tensor parallel served before an update is kept on the prior alone, and the line says why",
        keptTensor.chosen?.mode == .tensorParallel && keptTensor.tensorParallel?.evidence == .priorOnly
            && reason(keptTensor) == "Tensor parallel: kept after the update.")
    // The developer setting still places it with no share probe (that load records the first one), and the router
    // prices a chosen setup as it was planned.
    var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
    checks.require("Gemma fastest plan: the developer's forced mode still places tensor parallel, with no share probe",
        try plan(ultras, forced, .unmeasured).chosen?.mode == .tensorParallel)
    let priced = try ClusterPlacementPlanner.evaluate(devices: small, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
        layout: layout, policy: first(128, 128), link: .unmeasured)
    checks.require("Gemma fastest plan: a tensor-parallel setup chosen before the link was measured is priced on the conservative assumed reduction",
        priced.prediction(.rested).decodeTokensPerSecond > 0)
}

/// The same layout with its plan's choice removed: a family that keeps the tensor-parallel-first rule.
private func gemmaTensorParallelFirst(_ layout: ClusterModelLayout) throws -> ClusterModelLayout {
    var object = try JSONSerialization.jsonObject(with: layout.encoded()) as? [String: Any] ?? [:]
    var tp = object["tensorParallel"] as? [String: Any] ?? [:]
    var family = tp["family"] as? [String: Any] ?? [:]
    family["choice"] = nil; tp["family"] = family; object["tensorParallel"] = tp
    return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

/// Two M5 Ultras 256 GB (DevNet, 2026-11-05) on their measured keyed link, Gemma 4 26B never measured whole on them, its
/// tensor parallel served at 105 tok/s and probed at about 7 ms a half step: the question recommended the pipeline,
/// "about 183 against 107 tokens/s, predicted", and 59.9 against 105.1 were served. The pipeline's step was the device
/// index's whole-model estimate, the weights' read time alone (5.5 ms), below the half step measured on the same Mac.
/// The whole step is now at least a measured share's step plus the rest of the weights: tensor parallel is predicted
/// faster, from the Macs' own index and measurements. With nothing of Gemma measured, the estimate stands as before.
private func checkGemmaPairModePrediction(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/gemma-4-26b-qat-4bit.json")))
    // The pair's own probe (two M5 Ultras, keyed JACCL): sealed all-sum 29 us at 16 KB, 3,919 us at 32 MiB.
    let link = ClusterLinkCosts(probe: ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
        pointToPointSmallMicroseconds: 180, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 2_502,
        allSumSmallBytes: 16_384, allSumSmallMicroseconds: 29, allSumLargeBytes: 32 << 20, allSumLargeMicroseconds: 3_919),
        measuredUTC: "2026-10-31T00:00:00Z")!
    var profile = try SyntheticMac.idle(256).profile(chip: "Apple M5 Ultra")
    profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: 2_337_768, decodeIndex: 46_409)
    let profiles = [("mac-a", profile), ("mac-b", profile)]
    // As every plan of the pair reads them (`ClusterPlacementFlow.decide`): estimated, then the index's absolute rates.
    let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: [], indices: profiles.compactMap { $0.1.speedIndex })
    let fresh = ClusterHardwarePrior.absolute(zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) },
        layout: layout, link: link)
    var policy = ClusterPlacementPolicy(); policy.promptTokens = 128; policy.outputTokens = 128
    func decode(_ devices: [ClusterPlacementDevice]) throws -> (pipeline: Double, tensor: Double) {
        let pipeline = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [15], mode: .pipeline, prefillSchedule: .serial,
            layout: layout, policy: policy, link: link)
        let tensor = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
            layout: layout, policy: policy, link: link)
        return (pipeline.rested.decodeTokensPerSecond, tensor.rested.decodeTokensPerSecond)
    }
    func line(_ d: (pipeline: Double, tensor: Double)) -> String { String(format: "pipeline %.0f, tensor parallel %.0f tok/s", d.pipeline, d.tensor) }
    checks.require("gemma 2x M5 Ultra: the index alone is an estimate of the whole model, and says so",
        fresh.allSatisfy { $0.speed.source == .transferredByDeviceIndex && $0.speed.wholeModelEstimated == true })
    let unmeasured = try decode(fresh)
    checks.require("gemma 2x M5 Ultra, nothing of Gemma measured: the index's estimate stands (\(line(unmeasured)))",
        unmeasured.pipeline > 160 && unmeasured.pipeline < 175)
    let probed = try decode(withShareProbes(fresh, layout: layout, halfStepMicroseconds: 7_000))
    let served = try afterServedTensorParallel(withShareProbes(fresh, layout: layout, halfStepMicroseconds: 7_000), layout: layout, link: link,
        decode: 105, prompt: 128, outputs: 128)
    let afterServing = try decode(served)
    for (name, d) in [("share probes at 7 ms a half step", probed), ("served in tensor parallel at 105 tok/s", afterServing)] {
        checks.require("gemma 2x M5 Ultra, \(name): tensor parallel is predicted faster than the pipeline (\(line(d))); 105 and 60 were served",
            d.tensor > d.pipeline && d.pipeline < 105)
    }
    checks.require("gemma 2x M5 Ultra, served: the served record's whole-model rate is marked an estimate",
        served.allSatisfy { $0.speed.source == .measured && $0.speed.wholeModelEstimated == true })
    // A Mac's own whole-model measurement is never overridden: 90 tok/s measured, the pipeline predicts from it.
    let measuredWhole = fresh.map { ClusterPlacementDevice(label: $0.label, profile: $0.profile, speed: measured(prefill: 7_000, decode: 90)) }
    let wholeKept = try decode(withShareProbes(measuredWhole, layout: layout, halfStepMicroseconds: 7_000))
    checks.require("gemma 2x M5 Ultra, whole model measured at 90 tok/s: the pipeline predicts from that measurement (\(line(wholeKept)))",
        wholeKept.pipeline > 85 && wholeKept.pipeline < 90)
}

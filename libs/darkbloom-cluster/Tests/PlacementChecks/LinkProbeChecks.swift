import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The link a tensor-parallel load measured (`ClusterWorkerLinkProbe`, in the
/// worker's ready record) becomes the planner's link costs
/// (`ClusterLinkCosts(probe:)`), so tensor parallel or pipeline is chosen from
/// detected hardware and the measured link with no user step. Constructed
/// Macs (floor-plus-bandwidth inputs, not claims about those machines) and the
/// recorded M3 Ultra + M5 Ultra profiles with the rates this pair measured on
/// 2026-10-14 (per-share decode steps, sealed all-sum, the pipeline served).
/// No model, no GPU, no network: not a hardware pass.
func checkLinkProbe(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    try checkProbeCosts(checks)
    try checkProbeChoiceSynthetic(big, checks)
    try checkProbeChoiceRecordedPair(big, golden: golden, checks)
}

func rdmaProbe(allSumSmallMicroseconds: Int = 33, allSumLargeMicroseconds: Int = 4_000, keyed: Bool = true) -> ClusterWorkerLinkProbe {
    ClusterWorkerLinkProbe(transport: "jaccl", keyed: keyed, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 20,
        pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 1_100, allSumSmallBytes: 20_480,
        allSumSmallMicroseconds: allSumSmallMicroseconds, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: allSumLargeMicroseconds)
}

private func checkProbeCosts(_ checks: PlacementChecks) throws {
    let probe = rdmaProbe()
    guard let costs = ClusterLinkCosts(probe: probe, measuredUTC: "2026-10-14T15:00:00Z") else {
        checks.require("link probe: a valid keyed probe gives link costs", false); return
    }
    let perByte = (4_000e-6 - 33e-6) / Double(10_485_760 - 20_480)
    checks.require("link probe: the reduction is the sealed all-sum's fixed part and per-byte slope, keyed",
        costs.measured && costs.reduction?.keyed == true
            && abs((costs.reduction?.secondsPerByte ?? 0) - perByte) < 1e-15
            && abs((costs.reduction?.seconds(bytes: 20_480) ?? 0) - 33e-6) < 1e-9
            && abs((costs.reduction?.seconds(bytes: 10_485_760) ?? 0) - 4_000e-6) < 1e-9)
    checks.require("link probe: a pipeline decode step pays two one-way records; a chunk hop one large record",
        abs((costs.perDecodeStepSeconds[ClusterGenerationMode.pipeline.rawValue] ?? 0) - 40e-6) < 1e-9
            && abs((costs.perDecodeStepSeconds[ClusterGenerationMode.pipelineCompactDecode.rawValue] ?? 0) - 40e-6) < 1e-9
            && abs(costs.perChunkSeconds - 1_100e-6) < 1e-9
            && abs(costs.handoffSecondsPerByte - (1_100e-6 - 20e-6) / Double((4 << 20) - 64)) < 1e-15)
    checks.require("link probe: a served pipeline step overrides the probe's raw record time",
        ClusterLinkCosts(probe: probe, measuredUTC: "t", servedPipelineStepSeconds: 0.008)?
            .perDecodeStepSeconds[ClusterGenerationMode.pipeline.rawValue] == 0.008)
    checks.require("link probe: an unkeyed probe gives an unkeyed reduction (never chosen on)",
        ClusterLinkCosts(probe: rdmaProbe(keyed: false), measuredUTC: "t")?.reduction?.keyed == false)
    let invalid = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 0,
        pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 1_100, allSumSmallBytes: 20_480,
        allSumSmallMicroseconds: 33, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 4_000)
    checks.require("link probe: a malformed probe gives no costs", ClusterLinkCosts(probe: invalid, measuredUTC: "t") == nil)
    // A large all-sum faster per byte than nothing: the slope is never negative.
    checks.require("link probe: a non-increasing large all-sum gives a zero slope, not a negative one",
        ClusterLinkCosts(probe: rdmaProbe(allSumSmallMicroseconds: 50, allSumLargeMicroseconds: 40), measuredUTC: "t")?
            .reduction?.secondsPerByte == 0)
}

private func shardPolicy(prompt: Int, outputs: Int) -> ClusterPlacementPolicy {
    var p = ClusterPlacementPolicy()
    p.promptTokens = prompt; p.outputTokens = outputs
    return p
}

private func checkProbeChoiceSynthetic(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let weights = big.wholeModelLoadedBytes
    let layout = try executing(big, [.tensorParallel])
    struct Mac { let gib: Double; let chip: String; let floor: Double; let bw: Double; let prefill: Double }
    let m1max = Mac(gib: 64, chip: "Apple M1 Max", floor: 25, bw: 400, prefill: 120)
    let m2max = Mac(gib: 96, chip: "Apple M2 Max", floor: 22, bw: 400, prefill: 150)
    let m2ultra = Mac(gib: 192, chip: "Apple M2 Ultra", floor: 20, bw: 800, prefill: 260)
    // Constructed: a 33 us sealed all-sum at a decode step and about 5 GB/s
    // for a prefill chunk's (the parallel-piece sealing's expectation).
    let fast = ClusterLinkCosts(probe: rdmaProbe(allSumLargeMicroseconds: 2_100), measuredUTC: "t")!
    let slow = ClusterLinkCosts(probe: rdmaProbe(allSumSmallMicroseconds: 400, allSumLargeMicroseconds: 30_000), measuredUTC: "t")!
    for (name, a, b) in [("2x M1 Max 64 GB", m1max, m1max), ("2x M2 Ultra 192 GB", m2ultra, m2ultra),
                         ("M1 Max 64 GB + M2 Max 96 GB", m1max, m2max)] {
        let pair = [try SyntheticMac.idle(a.gib).device("a", speed: modelled(floorMs: a.floor, bandwidthGBs: a.bw, weightBytes: weights, prefill: a.prefill), chip: a.chip),
                    try SyntheticMac.idle(b.gib).device("b", speed: modelled(floorMs: b.floor, bandwidthGBs: b.bw, weightBytes: weights, prefill: b.prefill), chip: b.chip)]
        let chosenFast = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: shardPolicy(prompt: min(1024, layout.maximumPromptTokens), outputs: min(512, layout.maximumOutputTokens)), link: fast).chosen
        let chosenSlow = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: shardPolicy(prompt: min(1024, layout.maximumPromptTokens), outputs: min(512, layout.maximumOutputTokens)), link: slow).chosen
        checks.require("link probe \(name): a fast keyed RDMA probe (33 us all-sum) chooses tensor parallel for a bandwidth-bound decode",
            chosenFast?.mode == .tensorParallel)
        checks.require("link probe \(name): a slow probe (400 us all-sum) chooses a pipeline",
            chosenSlow.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true)
    }
}

/// The pair as measured on 2026-10-14 (27B, greedy, all four lanes): per-share
/// decode steps of each Mac alone (M3 Ultra 1/4 15.86 ms, 1/2 24.61, 3/4 32.87,
/// whole 26.14; M5 Ultra 10.17, 15.77, 21.22, 17.99), prefill alone and per
/// share, the sealed all-sum (about 33 us at a decode step, about 4 ms at a
/// 512-token chunk) and the pipeline as served (27 ms per decode step at cut 8
/// against about 19 ms of compute: 8 ms per step on top of the link probe).
private func checkProbeChoiceRecordedPair(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    let a = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-a.json")))
    let b = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-mac-b.json")))
    func speed(prefill: Double, decodeStepMs: Double, shares: [(Int, Double, Double?)]) -> ClusterDeviceSpeed {
        let half = shares.first { $0.0 == 500 }
        return .init(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: 1000 / decodeStepMs,
                tensorShardPrefillTokensPerSecond: half?.2, tensorShardDecodeTokensPerSecond: half.map { 1000 / $0.1 },
                tensorShareRates: shares.filter { $0.0 != 500 }.map {
                    ClusterShareRate(sharePerMille: $0.0, decodeTokensPerSecond: 1000 / $0.1, prefillTokensPerSecond: $0.2) }),
            sustained: nil, explanation: "measured on the pair, 2026-10-14")
    }
    let devices = [ClusterPlacementDevice(label: "mac-a", profile: a,
                       speed: speed(prefill: 322, decodeStepMs: 26.14, shares: [(250, 15.86, 1152), (500, 24.61, 598), (750, 32.87, nil)])),
                   ClusterPlacementDevice(label: "mac-b", profile: b,
                       speed: speed(prefill: 1601, decodeStepMs: 17.99, shares: [(250, 10.17, nil), (500, 15.77, 2670), (750, 21.22, 1824)]))]
    let layout = try executing(big, [.tensorParallel])
    let link = ClusterLinkCosts(probe: rdmaProbe(), measuredUTC: "t", servedPipelineStepSeconds: 0.008)!
    let outputs = min(2048, layout.maximumOutputTokens), longPrompt = min(16_384, layout.maximumPromptTokens)
    let long = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: shardPolicy(prompt: min(1024, layout.maximumPromptTokens), outputs: outputs), link: link)
    let prompt = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: shardPolicy(prompt: longPrompt, outputs: 128), link: link)
    func option(_ r: ClusterPlacementResult, _ kind: ClusterShardOption.Kind) -> ClusterShardOption? {
        r.shards?.options.first { $0.kind == kind }
    }
    let tpOption = option(long, .tensorParallel), ppDecode = [option(long, .pipeline), option(long, .pipelineCompactDecode)]
        .compactMap { $0?.prediction?.decodeTokensPerSecond }.max() ?? .infinity
    let shares = tpOption?.shares ?? []
    let m5uShare = zip(tpOption?.members ?? [], shares).first { $0.0.device == "mac-b" }?.1 ?? 0
    checks.require("link probe M3 Ultra + M5 Ultra: tensor parallel decodes faster than the served pipeline (as measured: 39.8 vs 37.1 tok/s), with the larger share on the M5 Ultra",
        (tpOption?.prediction?.decodeTokensPerSecond ?? 0) > ppDecode && m5uShare > 0.5)
    checks.require("link probe M3 Ultra + M5 Ultra, 1K prompt + \(outputs) output: a pipeline (as measured: 4.4 s against 5.6 s; tensor parallel's prefill loses more than its decode gains)",
        long.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true)
    checks.require("link probe M3 Ultra + M5 Ultra, \(longPrompt) prompt + 128 output: a pipeline (tensor-parallel prefill pays 129 sealed reductions per chunk)",
        prompt.chosen.map { $0.mode == .pipeline || $0.mode == .pipelineCompactDecode } == true)
}

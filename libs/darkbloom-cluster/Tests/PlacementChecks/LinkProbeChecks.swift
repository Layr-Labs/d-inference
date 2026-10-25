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
    try checkProbeHistory(checks)
    try checkProbeHistoryChoice(big, checks)
    try checkPlanToolSavedLink(big, golden: golden, checks)
}

/// A load's probe with the sealed all-sum's fixed part at `fixedMicroseconds`
/// and the per-byte slope of the fast probe below (2,067 us more at 10 MiB
/// than at 20 KB), as the pair's loads differed (43 to 109 us, 2026-10-23).
private func load(_ fixedMicroseconds: Int, keyed: Bool = true) -> ClusterWorkerLinkProbe {
    rdmaProbe(allSumSmallMicroseconds: fixedMicroseconds, allSumLargeMicroseconds: fixedMicroseconds + 2_067, keyed: keyed)
}

private func utc(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)) }

/// The pair's recent loads (`ClusterLinkProbeHistory`): the last eight in
/// date, in one file an earlier build still reads, give the planner their
/// median (`ClusterLinkCosts(measurements:)`). Constructed probes.
private func checkProbeHistory(_ checks: PlacementChecks) throws {
    typealias M = ClusterLinkProbeHistory.Measurement
    let now = 1_800_000_000.0
    func figures(_ c: ClusterLinkCosts?) -> [Double] {
        guard let c, let r = c.reduction else { return [] }
        return [r.fixedSeconds, r.secondsPerByte, c.perChunkSeconds, c.handoffSecondsPerByte,
                c.perDecodeStepSeconds[ClusterGenerationMode.pipeline.rawValue] ?? -1]
    }
    func same(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && !a.isEmpty && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-12 * max(1, abs($1)) } }
    checks.require("link history: one load gives exactly that load's probe costs",
        ClusterLinkCosts(measurements: [M(measuredAt: now, probe: load(43))]) == ClusterLinkCosts(probe: load(43), measuredUTC: utc(now)))
    let five = [43, 109, 72, 60, 95].enumerated().map { M(measuredAt: now - Double($0.offset) * 3_600, probe: load($0.element)) }
    let median = ClusterLinkCosts(measurements: five)
    checks.require("link history: five loads give each figure's median (the 72 us load's, of 43 to 109 us), not the latest load's (43 us)",
        same(figures(median), figures(ClusterLinkCosts(probe: load(72), measuredUTC: "t"))) && median?.reduction?.keyed == true
            && !same(figures(median), figures(ClusterLinkCosts(probe: load(43), measuredUTC: "t"))))
    checks.require("link history: the order the loads are given in does not matter", median == ClusterLinkCosts(measurements: five.reversed()))
    checks.require("link history: the provenance names the loads and their spread",
        median?.provenance.hasPrefix("the median of 5 loads' probes over jaccl (keyed, sealed all-sums), measured \(utc(now - 4 * 3_600)) to \(utc(now))") == true
            && median?.provenance.contains("across the loads") == true && (median?.provenance.utf8.count ?? 2_000) <= 1_024)
    let even = ClusterLinkCosts(measurements: Array(five.prefix(4)))
    let middle = (ClusterLinkCosts(probe: load(60), measuredUTC: "t")!.reduction!.fixedSeconds
        + ClusterLinkCosts(probe: load(72), measuredUTC: "t")!.reduction!.fixedSeconds) / 2
    checks.require("link history: an even count takes the mean of the two middle figures", abs((even?.reduction?.fixedSeconds ?? 0) - middle) < 1e-15)
    let odd = (1...5).map { M(measuredAt: now - Double($0) * 60, probe: load(43)) } + [M(measuredAt: now, probe: load(400))]
    checks.require("link history: one odd load, even the latest, does not move the median",
        same(figures(ClusterLinkCosts(measurements: odd)), figures(ClusterLinkCosts(probe: load(43), measuredUTC: "t"))))
    let mixed = five + [M(measuredAt: now + 60, probe: load(5, keyed: false)), M(measuredAt: now + 120, probe: load(6, keyed: false))]
    checks.require("link history: plaintext loads (a qualification run) do not move the keyed median; only keyed loads choose tensor parallel",
        same(figures(ClusterLinkCosts(measurements: mixed)), figures(median)) && ClusterLinkCosts(measurements: mixed)?.reduction?.keyed == true)
    checks.require("link history: plaintext loads alone give an unkeyed reduction (never chosen on)",
        ClusterLinkCosts(measurements: [M(measuredAt: now, probe: load(43, keyed: false))])?.reduction?.keyed == false)
    checks.require("link history: no load gives no costs (unmeasured)", ClusterLinkCosts(measurements: []) == nil)

    var history = ClusterLinkProbeHistory()
    for index in 0..<10 { history = history.recording(load(40 + index), members: ["b", "a"], now: now + Double(index)) }
    let kept = history.measurements(members: ["a", "b"], now: now + 10)
    checks.require("link history: a pair keeps its last 8 loads, newest first, in either member order",
        kept.count == ClusterLinkProbeHistory.maximumMeasurements && kept.first?.probe == load(49) && kept.last?.probe == load(42)
            && kept.map(\.measuredAt) == kept.map(\.measuredAt).sorted(by: >))
    let other = history.recording(load(70), members: ["a", "c"], now: now + 20)
    checks.require("link history: another pair's loads are its own; this pair's stay",
        other.measurements(members: ["c", "a"], now: now + 20).count == 1 && other.measurements(members: ["a", "b"], now: now + 20).count == 8)
    checks.require("link history: a load older than 30 days is not used",
        history.measurements(members: ["a", "b"], now: now + ClusterLinkProbeHistory.maximumAgeSeconds + 5.5).count == 4)
    checks.require("link history: a load dated ahead of the clock is not used",
        history.measurements(members: ["a", "b"], now: now - 400).isEmpty)
    let later = history.recording(load(80), members: ["a", "b"], now: now + ClusterLinkProbeHistory.maximumAgeSeconds + 5.5)
    checks.require("link history: recording drops the loads out of date",
        later.pairs["a|b"]?.measurements.count == 5 && later.pairs["a|b"]?.probe == load(80))

    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(history)
    checks.require("link history: what is written reads back, well inside the bound", ClusterLinkProbeHistory.decode(bytes) == history
        && bytes.count * ClusterLinkProbeHistory.maximumPairs < ClusterLinkProbeHistory.maximumBytes)
    // An earlier build's reader: a schema and one measurement a pair, nothing else.
    struct EarlierEntry: Decodable { let measuredAt: Double; let probe: ClusterWorkerLinkProbe }
    struct Earlier: Decodable { let schema: String; let pairs: [String: EarlierEntry] }
    let earlier = try? JSONDecoder().decode(Earlier.self, from: bytes)
    checks.require("link history: an earlier build reads this file's latest load where it read it",
        earlier?.schema == ClusterLinkProbeHistory.schemaName && earlier?.pairs["a|b"]?.probe == load(49)
            && earlier?.pairs["a|b"]?.measuredAt == now + 9)
    // A file an earlier build wrote (one pair's file as kept on 2026-10-23, its labels replaced): one load.
    let old = Data(#"{"pairs":{"mac-a|mac-b":{"measuredAt":1792775899.275354,"probe":{"allSumLargeBytes":10485760,"allSumLargeMicroseconds":1296,"allSumSmallBytes":20480,"allSumSmallMicroseconds":38,"keyed":true,"pointToPointLargeBytes":4194304,"pointToPointLargeMicroseconds":2622,"pointToPointSmallBytes":64,"pointToPointSmallMicroseconds":167,"transport":"jaccl"}}},"schema":"darkbloom_cluster_link_probes_v1"}"#.utf8)
    let read = ClusterLinkProbeHistory.decode(old), measuredAt = 1792775899.275354
    let alone = read?.measurements(members: ["mac-b", "mac-a"], now: measuredAt + 60) ?? []
    checks.require("link history: a file an earlier build wrote reads as its one load, priced as before",
        alone.count == 1 && read?.costs(members: ["mac-a", "mac-b"], now: measuredAt + 60)
            == ClusterLinkCosts(probe: alone[0].probe, measuredUTC: utc(measuredAt)))
    checks.require("link history: the next load joins that file's load",
        read?.recording(load(50), members: ["mac-a", "mac-b"], now: measuredAt + 3_600).measurements(members: ["mac-a", "mac-b"],
            now: measuredAt + 3_600).count == 2)
    func edited(_ body: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        body(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    let otherSchema = try edited { $0["schema"] = "darkbloom_cluster_link_probes_v2" }
    let tooMany = try edited { object in
        var pairs = object["pairs"] as! [String: Any], entry = pairs["a|b"] as! [String: Any]
        var listed = entry["earlier"] as! [Any]; listed.append(listed[0]); entry["earlier"] = listed
        pairs["a|b"] = entry; object["pairs"] = pairs
    }
    let badProbe = try edited { object in
        var pairs = object["pairs"] as! [String: Any], entry = pairs["a|b"] as! [String: Any]
        var listed = entry["earlier"] as! [[String: Any]], probe = listed[0]["probe"] as! [String: Any]
        probe["transport"] = "tcp"; listed[0]["probe"] = probe; entry["earlier"] = listed
        pairs["a|b"] = entry; object["pairs"] = pairs
    }
    checks.require("link history: another schema, more loads than are kept, or a malformed earlier probe is refused whole",
        ClusterLinkProbeHistory.decode(otherSchema) == nil && ClusterLinkProbeHistory.decode(tooMany) == nil
            && ClusterLinkProbeHistory.decode(badProbe) == nil && ClusterLinkProbeHistory.decode(Data("{}".utf8)) == nil)
}

/// The mode follows the loads' median, not the latest load: on a pair where a
/// fast reduction (33 us) chooses tensor parallel and a slow one (400 us) a
/// pipeline, a slow latest load among fast ones keeps tensor parallel and a
/// fast latest among slow ones keeps the pipeline; planning on the latest load
/// alone flipped the mode each time (2026-10-23/24). Constructed Macs.
private func checkProbeHistoryChoice(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let layout = try executing(big, [.tensorParallel])
    let speed = modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: big.wholeModelLoadedBytes, prefill: 260)
    let pair = [try SyntheticMac.idle(192).device("a", speed: speed, chip: "Apple M2 Ultra"),
                try SyntheticMac.idle(192).device("b", speed: speed, chip: "Apple M2 Ultra")]
    let policy = shardPolicy(prompt: min(1024, layout.maximumPromptTokens), outputs: min(512, layout.maximumOutputTokens))
    func mode(_ link: ClusterLinkCosts?) throws -> ClusterGenerationMode? {
        guard let link else { return nil }
        return try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: policy, link: link).chosen?.mode
    }
    let now = 1_800_000_000.0
    func loads(_ micros: [Int]) -> [ClusterLinkProbeHistory.Measurement] {
        micros.enumerated().map { .init(measuredAt: now - Double($0.offset) * 3_600, probe: load($0.element)) }
    }
    let fastAlone = try mode(ClusterLinkCosts(probe: load(33), measuredUTC: "t"))
    let slowAlone = try mode(ClusterLinkCosts(probe: load(400), measuredUTC: "t"))
    checks.require("link history: on this pair a fast load alone chooses tensor parallel and a slow one a pipeline (\(slowAlone?.rawValue ?? "none"))",
        fastAlone == .tensorParallel && slowAlone.map { !$0.usesTensorParallelDecode } == true)
    checks.require("link history: a slow latest load among fast ones keeps tensor parallel",
        try mode(ClusterLinkCosts(measurements: loads([400, 33, 33, 400, 33]))) == .tensorParallel)
    checks.require("link history: a fast latest load among slow ones keeps the pipeline",
        try mode(ClusterLinkCosts(measurements: loads([33, 400, 400, 33, 400]))) == slowAlone)
}

/// `plan` given no `--link` plans two devices on the link probes the setup
/// saved for them (`ClusterLinkProbeHistory`, their median), says so, and
/// prints the reductions' cost in ms or us, never "0.00 s"; a file the setup
/// would not read is reported and left out, and a named one must hold the
/// pair. The recorded profiles and the 27B layout with its tensor-parallel
/// mode, temporary files only.
private func checkPlanToolSavedLink(_ big: ClusterModelLayout, golden: URL, _ checks: PlacementChecks) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("saved-link-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let layoutFile = scratch.appendingPathComponent("layout.json")
    try executing(big, [.tensorParallel]).encoded().write(to: layoutFile)
    let layout = layoutFile.path
    func plan(_ labels: [String] = ["mac-a", "mac-b"], _ extra: [String] = [], saved: URL?) throws -> String {
        let peers = zip(labels, ["mac-a", "mac-b"]).flatMap { ["--peer", "\($0)=" + golden.appendingPathComponent("profile-\($1).json").path] }
        return try ClusterPlacementTool.run(["plan", "--layout", layout] + peers + ["--leader", labels[0], "--prompt-tokens", "1024",
            "--output-tokens", "128"] + extra, sampleDevice: { throw ProbeError("recorded profiles only") }, savedLinkProbes: saved)
    }
    let now = Date().timeIntervalSince1970
    var history = ClusterLinkProbeHistory()
    for (index, micros) in [43, 109, 72].enumerated() {
        history = history.recording(load(micros), members: ["mac-b", "mac-a"], now: now - Double(3 - index) * 3_600)
    }
    let file = scratch.appendingPathComponent("link-probes.json")
    try JSONEncoder().encode(history).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let printed = try plan(saved: file)
    checks.require("plan tool: given no --link it plans on the probes saved for the pair, and says so",
        printed.hasPrefix("Link costs\n  No --link given: the median of the 3 link probes saved for mac-a and mac-b in \(file.path) (measured ")
            && printed.contains("as the setup plans with them.\n")
            && printed.contains("  Link and framing costs: the median of 3 loads' probes over jaccl (keyed, sealed all-sums)"))
    let reductions = printed.split(separator: "\n").first { $0.contains("reductions per decode step cost") }.map(String.init) ?? ""
    checks.require("plan tool: the reductions a decode step pays are priced in ms or µs, each one too (\(reductions))",
        reductions.contains("129 reductions per decode step cost ") && !reductions.contains("0.00 s")
            && (reductions.contains(" ms over the link") || reductions.contains(" µs over the link")) && reductions.contains(" µs each).")
            && !printed.contains("reductionNotMeasured"))
    checks.require("plan tool: --link-probes FILE plans as the saved file does", try plan(["mac-a", "mac-b"], ["--link-probes", file.path], saved: nil) == printed)
    let json = try JSONSerialization.jsonObject(with: Data(plan(["mac-a", "mac-b"], ["--json"], saved: file).utf8)) as? [String: Any]
    checks.require("plan tool: the JSON plan carries the median link and the line",
        ((json?["link"] as? [String: Any])?["provenance"] as? String)?.hasPrefix("the median of 3 loads' probes") == true
            && (json?["explanation"] as? [String])?.first == "Link costs")
    let unread = try plan(saved: nil)
    checks.require("plan tool: with no saved file passed (a check) nothing is read or said: unmeasured as before",
        !unread.contains("Link costs") && unread.contains("reductionNotMeasured"))
    let absent = try plan(saved: scratch.appendingPathComponent("absent.json"))
    checks.require("plan tool: no saved file: said, and planned unmeasured",
        absent.contains("  No --link given: no link probes are saved at ") && absent.contains("reductionNotMeasured"))
    let strangers = try plan(["x", "y"], saved: file)
    checks.require("plan tool: devices that are not the saved pair: said, with the pairs the file holds, and planned unmeasured",
        strangers.contains("holds no probe for x and y (the setup saves pairs by member ID: mac-a|mac-b)") && strangers.contains("reductionNotMeasured"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    let shared = try plan(saved: file)
    checks.require("plan tool: a saved file others can read is not used, as the setup does not use it",
        shared.contains("is not used: it is not a file of this user's that only this user can read") && shared.contains("reductionNotMeasured"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    checks.refuses("plan tool: a named file without the pair stops the plan", because: "--link-probes: ") {
        _ = try plan(["x", "y"], ["--link-probes", file.path], saved: nil)
    }
    checks.refuses("plan tool: --link and --link-probes together are refused", because: "Give --link or --link-probes, not both") {
        _ = try plan(["mac-a", "mac-b"], ["--link", file.path, "--link-probes", file.path], saved: nil)
    }
    let single = scratch.appendingPathComponent("single.json")
    try JSONEncoder().encode(ClusterLinkProbeHistory().recording(load(43), members: ["mac-a", "mac-b"], now: now - 60)).write(to: single)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: single.path)
    checks.require("plan tool: one saved load is said as one",
        try plan(saved: single).contains("  No --link given: the one link probe saved for mac-a and mac-b in \(single.path) (measured "))
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

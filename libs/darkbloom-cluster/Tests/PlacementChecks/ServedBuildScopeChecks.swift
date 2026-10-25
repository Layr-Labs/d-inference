import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// A served speed counts only for the worker build that served it
/// (`ClusterServedSpeedRecords.servedBy`), as a share probe does: a plan uses
/// the records every rank of which ran the build the plan is for, and a
/// record written before builds were recorded counts as another build's.
/// The regression is the M3 Ultra + M5 Max pair's own leader file, kept until
/// 2026-10-25 09:21 UTC across builds before c42 (one night with the M3 Ultra
/// busy), while the pair stayed at 3:2 where c41's share probes balance the
/// 27B 1:1: taken as the current build's, its records rescale every share
/// point and change the plan's predictions; as they are, the plan is the one
/// made without them. Constructed requests and recorded figures only: no
/// model, no GPU, no network; not a hardware pass.
func checkServedBuildScope(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    checkServedBuildSetups(checks)
    try checkServedBuildRecords(checks)
    try checkServedBuildRegression(inputs, golden: golden, checks)
}

private let buildA = String(repeating: "a", count: 64), buildB = String(repeating: "b", count: 64)

private func setup(_ ranks: [String]?, _ builds: [String]?, mode: ClusterGenerationMode = .tensorParallel,
                   cut: String = "0-64|0-64") -> ClusterServedSpeedRecords.Setup {
    .init(modelID: "m", mode: mode.rawValue, cut: cut, ranks: ranks, rankBuildSHA256: builds)
}

private func sample(_ index: Int, decode: Double = 30) -> ClusterServedSample {
    .init(route: .pair, member: nil, promptTokens: 1024, outputTokens: 128, firstTokenSeconds: 1.2,
          decodeTokensPerSecond: decode, finishedAt: Double(1_000 + index))
}

/// Which setups a plan for each member's build may use.
private func checkServedBuildSetups(_ checks: PlacementChecks) {
    let pair = ["m3": buildA, "m5": buildA]
    checks.require("served build scope: a setup every rank of which ran the plan's build is the plan's, in either rank order",
        setup(["m3", "m5"], [buildA, buildA]).servedBy(pair) && setup(["m5", "m3"], [buildA, buildA]).servedBy(pair))
    checks.require("served build scope: another build on any rank, no build (written before builds were recorded), no ranks, a member the plan does not have, or builds that do not line up with the ranks are not",
        !setup(["m3", "m5"], [buildA, buildB]).servedBy(pair) && !setup(["m3", "m5"], [buildB, buildB]).servedBy(pair)
            && !setup(["m3", "m5"], nil).servedBy(pair) && !setup(nil, [buildA, buildA]).servedBy(pair)
            && !setup(["m3", "m9"], [buildA, buildA]).servedBy(pair) && !setup(["m3", "m5"], [buildA]).servedBy(pair)
            && !setup([], []).servedBy(pair) && !setup(["m3", "m5"], [buildA, buildA]).servedBy([:]))
    let mixed = ["m3": buildA, "m5": buildB]
    checks.require("served build scope: each member's own build counts at its own rank",
        setup(["m3", "m5"], [buildA, buildB]).servedBy(mixed) && setup(["m5", "m3"], [buildB, buildA]).servedBy(mixed)
            && !setup(["m5", "m3"], [buildA, buildB]).servedBy(mixed))
}

/// The records format: an old file reads (as another build's), a new one keeps
/// its builds, a malformed build is not kept, and a calibration of one build
/// never takes another build's samples.
private func checkServedBuildRecords(_ checks: PlacementChecks) throws {
    let pair = ["m3": buildA, "m5": buildA]
    let entries = (0..<3).map { ClusterServedSpeedRecords.Entry(setup: setup(["m3", "m5"], [buildA, buildA]), sample: sample($0)) }
        + (0..<2).map { ClusterServedSpeedRecords.Entry(setup: setup(["m3", "m5"], [buildB, buildB]), sample: sample($0)) }
        + [ClusterServedSpeedRecords.Entry(setup: setup(["m3", "m5"], nil), sample: sample(9))]
    let scoped = ClusterServedSpeedRecords.servedBy(pair, entries)
    checks.require("served build scope: the plan keeps its build's three records and counts the three others (two of another build, one without a build)",
        scoped.current.count == 3 && scoped.current.allSatisfy { $0.setup.rankBuildSHA256 == [buildA, buildA] } && scoped.otherBuilds == 3)
    let line = ClusterServedSpeedRecords.otherBuildsLine(scoped.otherBuilds, builds: pair)
    checks.require("served build scope: the plan says so in one line, naming the build it is for (\(line ?? "none"))",
        line == "  3 record(s) from other worker builds ignored: a served speed counts only for the build that served it (this plan is for worker build aaaaaaaaaaaa)"
            && ClusterServedSpeedRecords.otherBuildsLine(0, builds: pair) == nil
            && ClusterServedSpeedRecords.otherBuildsLine(2, builds: ["m3": buildB, "m5": buildA])?.hasSuffix("(this plan is for worker builds aaaaaaaaaaaa, bbbbbbbbbbbb)") == true)
    // A records file written before builds were recorded reads, every setup without builds.
    var records = ClusterServedSpeedRecords(entries: entries)
    let encoded = try records.encoded()
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object["entries"] = (object["entries"] as! [[String: Any]]).map { entry in
        var entry = entry, setup = entry["setup"] as! [String: Any]
        setup["rankBuildSHA256"] = nil; entry["setup"] = setup
        return entry
    }
    let old = try ClusterServedSpeedRecords.decode(JSONSerialization.data(withJSONObject: object))
    checks.require("served build scope: a records file written before builds were recorded reads, as no build's",
        old.entries.count == 6 && old.entries.allSatisfy { $0.setup.rankBuildSHA256 == nil }
            && ClusterServedSpeedRecords.servedBy(pair, old.entries).current.isEmpty)
    checks.require("served build scope: a records file with builds reads back as written",
        try ClusterServedSpeedRecords.decode(encoded) == records && String(decoding: encoded, as: UTF8.self).contains("\"rankBuildSHA256\""))
    let before = records
    records.add(sample(20), setup: setup(["m3", "m5"], ["not a build", buildA]))
    records.add(sample(21), setup: setup(["m3", "m5"], Array(repeating: buildA, count: 9)))
    checks.require("served build scope: a setup naming a malformed build, or more than eight builds, is not added",
        records == before)
    // One setup is one build's: two builds' samples of the same placement are two setups, never one median.
    let layout = try syntheticLayout(layers: 32, layerGiB: 0.25, modes: [.pipeline])
    let devices = [try SyntheticMac.idle(64).device("m3", speed: measured(prefill: 1_000, decode: 40)),
                   try SyntheticMac.idle(64).device("m5", speed: measured(prefill: 1_000, decode: 40))]
    let cut = ClusterServedSpeedRecords.Setup.cut([16], layerCount: 32)
    let two = (0..<3).map { ClusterServedSpeedRecords.Entry(setup: setup(["m3", "m5"], [buildA, buildA], mode: .pipeline, cut: cut),
                                                           sample: sample($0, decode: 20)) }
        + (0..<3).map { ClusterServedSpeedRecords.Entry(setup: setup(["m3", "m5"], [buildB, buildB], mode: .pipeline, cut: cut),
                                                       sample: sample($0, decode: 60)) }
    let both = try ClusterServedCalibration.measurements(entries: two, devices: devices, layout: layout, link: .unmeasured,
        measuredUTC: "2026-10-25T00:00:00Z")
    checks.require("served build scope: two builds' records of one placement are calibrated as two setups (\(both.lines.count) lines)",
        both.lines.count == 2 && both.lines.allSatisfy { $0.contains("3 pair and 0 alone request(s)") })
}

/// The pair's leader file (`Golden/served/m3ultra-m5max-leader-2026-10-25.json`:
/// the real `served-speed.json` with its two member IDs written as the labels
/// m3 and m5 and its request IDs numbered; every planned value as served). It
/// names no build. The plan tool plans the 27B on these Macs as the setup does:
/// the 27B's own layout with tensor parallel, the two Macs' recorded profiles
/// with the speed indices the leader recorded (2026-10-23), the measured keyed
/// link, and c41's share probes at 3:2 (M3 Ultra 60 % in 18.4 ms plain, 41.0
/// ms per four-column window; M5 Max 40 % in 17.0 and 25.1 ms), whose windows
/// balance the split 1:1. The provider's own decision on the same inputs is
/// `PlacementSetupCheck.servedBuildRegression`, which reads the layout from
/// `Golden/served/qwen38-27b-tensor-parallel-layout.json`, checked here
/// against the registered headers.
private func checkServedBuildRegression(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let fixture = golden.appendingPathComponent("served/m3ultra-m5max-leader-2026-10-25.json")
    let layout = try executing(ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored), [.tensorParallel])
    let saved = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("served/qwen38-27b-tensor-parallel-layout.json")))
    checks.require("served build regression: the saved 27B tensor-parallel layout the provider check plans with is the registered headers' (\(layout.artifactSHA256.prefix(12)))",
        saved == layout && layout.tensorParallel != nil && layout.generationModes.contains(.tensorParallel))
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("served-build-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    func write(_ data: Data, _ name: String) throws -> String {
        let file = scratch.appendingPathComponent(name)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }
    func recorded(_ name: String, prefill: Double, decode: Double) throws -> ClusterDeviceProfile {
        var profile = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent(name)))
        profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: prefill, decodeIndex: decode)
        try profile.validate()
        return profile
    }
    let m3 = try recorded("profile-mac-a.json", prefill: 480_096.777_008_127_77, decode: 33_304.589_728_785_344)
    let m5 = try recorded("profile-mac-b.json", prefill: 1_303_482.955_744_106_6, decode: 43_947.553_400_780_285)
    checks.require("served build regression: the recorded profiles are the pair's M3 Ultra and M5 Max",
        m3.chip == "Apple M3 Ultra" && m5.chip == "Apple M5 Max")
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-25T09:00:00Z")!
    let now = Date().timeIntervalSince1970, current = String(repeating: "c", count: 64)
    let probes = ClusterShareProbeHistory().recording([
        .init(member: "m3", buildSHA256: current, probe: .init(sharePerMille: 600, plainStepMicroseconds: 18_400, windowColumns: 4,
            windowStepMicroseconds: 41_000, rounds: 7)),
        .init(member: "m5", buildSHA256: current, probe: .init(sharePerMille: 400, plainStepMicroseconds: 17_000, windowColumns: 4,
            windowStepMicroseconds: 25_100, rounds: 7))], artifactSHA256: layout.artifactSHA256, now: now - 60)
    let base = ["plan", "--layout", try write(layout.encoded(), "layout.json"),
        "--peer", "m3=" + (try write(m3.encoded(), "m3.json")), "--peer", "m5=" + (try write(m5.encoded(), "m5.json")),
        "--leader", "m3", "--link", try write(JSONEncoder().encode(link), "link.json"),
        "--share-probes", try write(JSONEncoder().encode(probes), "share-probes.json"),
        "--modes", ClusterGenerationMode.tensorParallel.rawValue, "--tensor-parallel-first",
        "--prompt-tokens", "128", "--output-tokens", "\(min(128, layout.maximumOutputTokens))", "--json"]
    func plan(_ extra: [String]) throws -> (shares: [Int], result: Data, lines: [String]) {
        let printed = try ClusterPlacementTool.run(base + extra, sampleDevice: { throw ProbeError("recorded profiles only") })
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any] ?? [:]
        let result = object["result"] as? [String: Any] ?? [:]
        let chosen = result["chosen"] as? [String: Any]
        return ((chosen?["tensorShares"] as? [Int]) ?? (chosen == nil ? [] : [1, 1]),
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), (object["explanation"] as? [String]) ?? [])
    }
    // The same records as if the build planning now had served them: what every plan before the fix did with them.
    var stamped = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
    let records = stamped["records"] as! [[String: Any]]
    stamped["records"] = records.map { record in
        var record = record
        record["rankBuildSHA256"] = [current, current]
        return record
    }
    let stampedFile = try write(JSONSerialization.data(withJSONObject: stamped, options: [.sortedKeys]), "served-stamped.json")
    let served = try ClusterPlacementTool.servedEntries([fixture.path], ranks: nil)
    checks.require("served build regression: the leader's file reads as \(served.count) speed records of the pair, none naming a build",
        served.count == records.count && served.allSatisfy { $0.setup.ranks == ["m3", "m5"] && $0.setup.rankBuildSHA256 == nil })

    let probed = try plan([])
    let asCurrent = try plan(["--served", stampedFile, "--served-build", current])
    let fixed = try plan(["--served", fixture.path, "--served-build", current])
    let unnamed = try plan(["--served", fixture.path])
    checks.require("served build regression: on c41's share probes alone the plan balances the 27B 1:1 (got \(probed.shares))",
        probed.shares == [1, 1])
    checks.require("served build regression: taken as this build's, the stale records are calibrated, every setup the pair served, and change the plan's predictions (shares \(asCurrent.shares)), as every plan before the fix took them",
        asCurrent.result != probed.result && asCurrent.lines.contains { $0.contains("tensor_parallel_v1 cut 0-64@3|0-64@2 (m3, m5)") }
            && asCurrent.lines.contains { $0.contains("pipeline_v1 cut 0-60|60-64 (m3, m5)") })
    checks.require("served build regression: as they are (no build), the records are ignored and the plan is byte for byte the one on the probes alone (got \(fixed.shares))",
        fixed.shares == probed.shares && fixed.result == probed.result)
    checks.require("served build regression: the plan says in one line why the \(records.count) records were not used",
        fixed.lines.contains("Speed records from served requests")
            && fixed.lines.contains("  \(records.count) record(s) from other worker builds ignored: a served speed counts only for the build that served it (this plan is for worker build cccccccccccc)")
            && !fixed.lines.contains { $0.contains("request(s) ->") })
    checks.require("served build regression: with no --served-build the tool cannot know the build and uses none of the records, and says so",
        unnamed.result == probed.result && unnamed.lines.contains { $0.contains("\(records.count) record(s) ignored") && $0.contains("no --served-build") })
    let otherBuild = try plan(["--served", stampedFile, "--served-build", buildB])
    checks.require("served build regression: records another build served are ignored by a plan for this one",
        otherBuild.result == probed.result && otherBuild.lines.contains { $0.hasPrefix("  \(records.count) record(s) from other worker builds ignored") })
    checks.refuses("served build regression: --served-build must be a build's SHA-256", because: "--served-build is a worker build's SHA-256") {
        _ = try plan(["--served", fixture.path, "--served-build", "c41"])
    }
    checks.refuses("served build regression: --served-build without --served is refused", because: "give --served too") {
        _ = try plan(["--served-build", current])
    }
    // The per-request route reads the records the same way.
    func route(_ extra: [String]) throws -> Int {
        let printed = try ClusterPlacementTool.run(["route", "--layout", base[2], "--peer", base[4], "--peer", base[6],
            "--cut", "60", "--mode", ClusterGenerationMode.pipeline.rawValue, "--ranks", "m3,m5", "--prompt-tokens", "256", "--json"] + extra,
            sampleDevice: { throw ProbeError("recorded profiles only") })
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        return object?["servedSamples"] as? Int ?? -1
    }
    let routed = (try route(["--served", stampedFile, "--served-build", current]), try route(["--served", fixture.path, "--served-build", current]),
                  try route(["--served", stampedFile]))
    checks.require("served build regression: the route prices the pipeline from this build's six records only (got \(routed))",
        routed == (6, 0, 0))
}

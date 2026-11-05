import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// A served record never fails a plan (2026-11-05): a pair of M5 Ultras served
/// the 27B in tensor parallel with 7 prompts of 71,545 to 94,423 tokens, over
/// the 65,536-token context its tensor-parallel allowance covers, and every
/// plan of the 27B on that pair then failed on them, so the model left the
/// pair's list. The pair's Qwen records are
/// `Golden/served/m5ultra-pair-qwen-over-limit-2026-11-05.json` (token counts,
/// durations and modes as served; members, builds and request IDs synthetic).
/// The 27B's layout is the product's, with its tensor-parallel allowance; the
/// provider's own decision on the same records is
/// `PlacementSetupCheck.servedOverLimitRegression`, which reads the layout
/// from `Golden/served/qwen38-27b-tensor-parallel-priced-layout.json`, checked
/// here against the registered headers. Recorded figures only: no model, no
/// GPU, no network; not a hardware pass.
func checkServedOverLimit(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let layout = try executing(ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored + QwenVisionBudgetFixture.read(golden).stored, tensorParallelAllocationBound: { $0 + 16_384 }),
        [.tensorParallel])
    let saved = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("served/qwen38-27b-tensor-parallel-priced-layout.json")))
    let allowance = layout.tensorParallel?.family.requestAllowance
    checks.require("served over limit: the saved priced 27B layout the provider check plans with is the registered headers' (vision tower included) at the allocator's bound, its tensor-parallel allowance covering a 65,536-token context (\(allowance?.maximumContextTokens ?? 0))",
        saved == layout && allowance?.maximumContextTokens == 65_536)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("served-over-limit-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    func write(_ data: Data, _ name: String) throws -> String {
        let file = scratch.appendingPathComponent(name)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }
    var ultra = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("pairs/m3ultra-m5ultra/profile-mac-b.json")))
    ultra.speedIndex = .init(chip: ultra.chip, osBuild: ultra.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: 2_337_768, decodeIndex: 46_409)
    try ultra.validate()
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-11-05T09:00:00Z")!
    let build = String(repeating: "d", count: 64), earlier = String(repeating: "e", count: 64)
    let fixture = golden.appendingPathComponent("served/m5ultra-pair-qwen-over-limit-2026-11-05.json")
    let file = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
    let records = file["records"] as! [[String: Any]]
    func served(_ keep: ([String: Any]) -> Bool = { _ in true }, builds: [String]? = nil) throws -> String {
        var copy = file
        copy["records"] = records.filter(keep).map { record in
            var record = record
            if let builds { record["rankBuildSHA256"] = builds }
            return record
        }
        return try write(JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]), "served-\(UUID().uuidString).json")
    }
    let base = ["plan", "--layout", try write(layout.encoded(), "layout.json"),
        "--peer", "ultra-a=" + (try write(ultra.encoded(), "ultra-a.json")), "--peer", "ultra-b=" + (try write(ultra.encoded(), "ultra-b.json")),
        "--leader", "ultra-a", "--link", try write(JSONEncoder().encode(link), "link.json"),
        "--modes", ClusterGenerationMode.tensorParallel.rawValue, "--tensor-parallel-first",
        "--prompt-tokens", "8192", "--output-tokens", "\(layout.maximumOutputTokens)", "--json"]
    func plan(_ extra: [String]) throws -> (result: Data, chosen: String?, lines: [String]) {
        let printed = try ClusterPlacementTool.run(base + extra, sampleDevice: { throw ProbeError("recorded profiles only") })
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any] ?? [:]
        let result = object["result"] as? [String: Any] ?? [:]
        return (try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                (result["chosen"] as? [String: Any])?["mode"] as? String, (object["explanation"] as? [String]) ?? [])
    }
    let outside = { (r: [String: Any]) -> Bool in
        (r["promptTokens"] as! Int) + (r["completionTokens"] as! Int) > (allowance?.maximumContextTokens ?? 0)
    }
    let current = records.filter { ($0["rankBuildSHA256"] as! [String]) == [build, build] }
    let over = current.filter(outside)
    checks.require("served over limit: the fixture is the pair's 32 Qwen records, 27 of this build, 7 of them prompts of 71,545 to 94,423 tokens over the 65,536-token context",
        records.count == 32 && current.count == 27 && over.count == 7 && records.filter(outside).count == 7
            && over.map { $0["promptTokens"] as! Int }.sorted() == [71_545, 77_122, 77_443, 80_313, 85_335, 93_086, 94_423])

    let all = try served()
    let unserved = try plan([])
    let decided: (result: Data, chosen: String?, lines: [String])
    do { decided = try plan(["--served", all, "--served-build", build]) } catch {
        checks.require("served over limit: the 27B is planned on the pair with its 7 over-limit records among the rest (failed: \(error))", false)
        return
    }
    checks.require("served over limit: the 27B is planned on the pair in tensor parallel (\(decided.chosen ?? "none"))",
        decided.chosen == ClusterGenerationMode.tensorParallel.rawValue)
    checks.require("served over limit: the plan says in one line that it skipped the 7 records, and the other 20 of this build still count",
        decided.lines.contains("  Skipped 7 speed records longer than the 65,536 tokens planning covers (the longest was 94,522); the other records still count")
            && decided.lines.contains { $0.hasPrefix("  tensor_parallel_v1 cut 0-64|0-64 (ultra-a, ultra-b): 20 pair and 0 alone request(s) ->") }
            && decided.lines.contains { $0.hasPrefix("  5 record(s) from other worker builds ignored") })
    // The records within the limits count exactly as they did: the plan is byte for byte the one made from them alone
    // (that they change the plan is `PlacementSetupCheck.servedOverLimitRegression`'s, on measured speeds).
    let within = try plan(["--served", try served { !outside($0) }, "--served-build", build])
    checks.require("served over limit: the plan is byte for byte the one made from the records within the limits alone, with the same line for them",
        decided.result == within.result && !within.lines.contains { $0.hasPrefix("  Skipped ") }
            && within.lines.contains { $0.hasPrefix("  tensor_parallel_v1 cut 0-64|0-64 (ultra-a, ultra-b): 20 pair and 0 alone request(s) ->") })
    // Records an earlier build kept: another build's are left out before they are evaluated; the same build's (a
    // worker build an update did not change) are evaluated and skipped. Neither fails the plan.
    let asEarlier = try plan(["--served", try served(builds: [earlier, earlier]), "--served-build", build])
    checks.require("served over limit: kept by another worker build, the records are ignored, the plan the one without them",
        asEarlier.result == unserved.result && asEarlier.lines.contains { $0.hasPrefix("  32 record(s) from other worker builds ignored") }
            && !asEarlier.lines.contains { $0.hasPrefix("  Skipped ") })
    let asCurrent = try plan(["--served", try served(builds: [build, build]), "--served-build", build])
    checks.require("served over limit: every record as this build's, the 7 are skipped and the 25 others count",
        asCurrent.chosen == ClusterGenerationMode.tensorParallel.rawValue
            && asCurrent.lines.contains { $0.hasPrefix("  Skipped 7 speed records longer than") }
            && asCurrent.lines.contains { $0.hasPrefix("  tensor_parallel_v1 cut 0-64|0-64 (ultra-a, ultra-b): 25 pair and 0 alone request(s) ->") })
    try checkServedOverLimitFallbacks(checks)
}

/// The calibration's two other ways around a record that cannot be used: a setup that cannot be calibrated even
/// after its unevaluable requests are skipped is skipped whole and counted, and a speculative speed-up that cannot
/// be recorded is said in one line. Neither fails the plan.
private func checkServedOverLimitFallbacks(_ checks: PlacementChecks) throws {
    let layout = try syntheticLayout(layers: 32, layerGiB: 0.25, modes: [.pipeline])
    let devices = [try SyntheticMac.idle(64).device("m3", speed: measured(prefill: 1_000, decode: 40)),
                   try SyntheticMac.idle(64).device("m5", speed: measured(prefill: 1_000, decode: 40))]
    let setup = ClusterServedSpeedRecords.Setup(modelID: "m", mode: ClusterGenerationMode.pipeline.rawValue,
        cut: ClusterServedSpeedRecords.Setup.cut([16], layerCount: 32), ranks: ["m3", "m5"])
    let alone = (0..<3).map { index in ClusterServedSpeedRecords.Entry(setup: setup, sample: .init(route: .alone, member: "m3",
        promptTokens: 1024, outputTokens: 128, firstTokenSeconds: 1.2, decodeTokensPerSecond: 30, finishedAt: Double(1_000 + index))) }
    // A measurement time longer than a speed record holds (64 bytes): no measurement of the setup can be written.
    let whole = try ClusterServedCalibration.measurements(entries: alone, devices: devices, layout: layout, link: .unmeasured,
        measuredUTC: String(repeating: "x", count: 65))
    checks.require("served over limit: a setup that cannot be calibrated at all is skipped whole and counted, not the plan's failure (\(whole.lines))",
        whole.measurements.isEmpty
            && whole.lines == ["  Skipped 3 speed records the plan could not evaluate on this model (the longest was 1,152 tokens); the other records still count"])
    let served = try ClusterServedCalibration.measurements(entries: alone, devices: devices, layout: layout, link: .unmeasured,
        measuredUTC: "2026-11-05T09:00:00Z")
    checks.require("served over limit: the same records with a valid time are calibrated, no line skipped",
        served.measurements.count == 1 && !served.lines.contains { $0.hasPrefix("  Skipped ") })
    checks.require("served over limit: the skipped line's numbers carry thousands separators and say the limit when every skipped record is over it",
        ClusterServedCalibration.skippedLine([], coveredTokens: 65_536) == nil
            && ClusterServedCalibration.skippedLine([.init(route: .pair, member: nil, promptTokens: 1_000_000, outputTokens: 234_567,
                firstTokenSeconds: 1, decodeTokensPerSecond: 1, finishedAt: 0)], coveredTokens: 65_536)
                == "  Skipped 1 speed record longer than the 65,536 tokens planning covers (the longest was 1,234,567); the other records still count")
    // The speculative pipeline's served speed-up rides on the plain pipeline's record; one that cannot hold the note
    // (its provenance over 1,024 bytes) is not credited, and the plan says so in one line.
    guard let plain = served.measurements.first else {
        checks.require("served over limit: the plain record to credit", false)
        return
    }
    let credited = ClusterServedCalibration.crediting(plain, pipelineSpeculativeFactor: 1.5)
    let full = try ClusterSpeedMeasurement(key: plain.key, promptTokens: plain.promptTokens, chunkTokens: plain.chunkTokens,
        probedLayers: plain.probedLayers, layerCount: plain.layerCount, rested: plain.rested, sustained: nil,
        measuredUTC: plain.measuredUTC, provenance: String(repeating: "p", count: 1_000))
    checks.require("served over limit: a speed-up is credited on the plain record, and one whose record cannot hold it is not",
        credited?.rested.pipelineSpeculativeFactor == 1.5 && ClusterServedCalibration.crediting(full, pipelineSpeculativeFactor: 1.5) == nil)
    checks.require("served over limit: an uncredited speed-up is said in one line, with what it can do to the plan",
        ClusterServedCalibration.uncreditedLine([]) == nil
            && ClusterServedCalibration.uncreditedLine(["m5"]) == "  The speculative pipeline's served speed-up on m5 is not credited (its speed record could not be updated): the plan predicts that pipeline at its plain decode there, so it may choose another mode even where the speculative pipeline served faster")
}

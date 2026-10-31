import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Each Mac's own share steps, timed at load (`ClusterWorkerShareProbe`) and
/// kept per model and member (`ClusterShareProbeHistory`), are what the
/// planner balances a tensor-parallel split by. The probe figures are the 27B's
/// local shard steps on the M3 Ultra + M5 Max pair with c38 kernels
/// (2026-10-24, one row, local reduction): M3 Ultra 2/3 32.1 ms, 1/2 24.9;
/// M5 Max 1/3 17.4, 1/2 26.1. The two Macs are constructed, their device
/// indices chosen so that the hardware prior alone gives the M3 Ultra the
/// larger share, as the product placed the 27B (2:1). No model, no GPU, no
/// network: not a hardware pass.
func checkMeasuredShareSteps(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    checkShareStepLine(checks)
    try checkShareProbeHistory(checks)
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    try checkShareProbePlans(try executing(big, [.tensorParallel]), checks)
}

private func rates(whole: Double, _ points: [(Int, Double)]) -> ClusterSpeedRates {
    .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / whole,
        tensorShareRates: points.map { ClusterShareRate(sharePerMille: $0.0, decodeTokensPerSecond: 1 / $0.1) })
}

/// The line a device's share steps follow once probes measured some: through
/// them, past them on the nearest segment (one probe: in proportion), never on
/// the whole model's step.
private func checkShareStepLine(_ checks: PlacementChecks) {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }
    let one = ClusterDecodeSplit(rates: rates(whole: 0.0261, [(667, 0.0321)]), hardwareWeightSeconds: 0.02)
    checks.require("share steps: one probe (2/3 in 32.1 ms) steps every share in proportion (1/2 in 24.06 ms, 3/4 in 36.09 ms), measured, the whole model's 26.1 ms no point and no hardware prior",
        close(one.shareStepSeconds(fraction: 0.667), 0.0321) && close(one.shareStepSeconds(fraction: 0.5), 0.0321 * 0.5 / 0.667)
            && close(one.shareStepSeconds(fraction: 0.75), 0.0321 * 0.75 / 0.667) && close(one.shareStepSeconds(ranks: 2), 0.0321 * 0.5 / 0.667)
            && one.measuredSteps?.map(\.fraction) == [0.667] && one.measured && one.fromHardware == nil)
    let two = ClusterDecodeSplit(rates: rates(whole: 0.0261, [(667, 0.0321), (500, 0.0249)]))
    let slope = (0.0321 - 0.0249) / (0.667 - 0.5)
    checks.require("share steps: two probes (1/2 in 24.9, 2/3 in 32.1 ms) step on the line through them, between them and past either",
        close(two.shareStepSeconds(fraction: 0.6), 0.0249 + 0.1 * slope) && close(two.shareStepSeconds(fraction: 0.4), 0.0249 - 0.1 * slope)
            && close(two.shareStepSeconds(fraction: 0.75), 0.0321 + (0.75 - 0.667) * slope))
    // A steep segment: its line would reach zero above a share of zero; a share's floor never shrinks with it.
    let steep = ClusterDecodeSplit(rates: rates(whole: 0.03, [(333, 0.0174), (500, 0.0300)]))
    checks.require("share steps: below the smallest probe never faster than in proportion to it",
        close(steep.shareStepSeconds(fraction: 0.1), 0.0174 * 0.1 / 0.333) && steep.shareStepSeconds(fraction: 0.1) > 0)
    checks.require("share steps: past the largest probe never slower than in proportion to it",
        close(steep.shareStepSeconds(fraction: 0.75), 0.03 * 0.75 / 0.5))
    // A falling segment (noise): a smaller share never steps slower, nor a larger one faster, than the nearest probe.
    let falling = ClusterDecodeSplit(rates: rates(whole: 0.05, [(250, 0.125), (500, 0.1)]))
    checks.require("share steps: a falling segment is held at the nearest probe's own step past it",
        close(falling.shareStepSeconds(fraction: 0.2), 0.125) && close(falling.shareStepSeconds(fraction: 0.75), 0.1))
    // The half probe (served equal shares) is one point among them; an explicit half still wins.
    let half = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 300, decodeTokensPerSecond: 1 / 0.0261,
        tensorShardDecodeTokensPerSecond: 1 / 0.026, tensorShareRates: [ClusterShareRate(sharePerMille: 333, decodeTokensPerSecond: 1 / 0.0174)]))
    checks.require("share steps: a half shard probe joins a share probe as a point (1/3 and 1/2 measured)",
        half.measuredSteps?.map(\.fraction) == [0.333, 0.5] && close(half.shareStepSeconds(ranks: 2), 0.026))
}

private func probe(_ share: Int, _ microseconds: Int, window: Int? = nil) -> ClusterWorkerShareProbe {
    .init(sharePerMille: share, plainStepMicroseconds: microseconds, windowColumns: window == nil ? nil : 4,
        windowStepMicroseconds: window, rounds: 7)
}

private func checkShareProbeHistory(_ checks: PlacementChecks) throws {
    let artifact = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
    let build = String(repeating: "c", count: 64), rebuilt = String(repeating: "d", count: 64)
    var history = ClusterShareProbeHistory().recording([
        .init(member: "m3", buildSHA256: build, probe: probe(667, 32_100, window: 56_600)),
        .init(member: "m5", buildSHA256: build, probe: probe(333, 17_400, window: 21_900))], artifactSHA256: artifact, now: 1_000)
    let read = history.shareRates(artifactSHA256: artifact, members: ["m3", "m5", "m9"], now: 2_000)
    checks.require("share probe history: both ranks' probes read back per member as share rates (a head-serving load's window: its four positions over the window step), no prefill",
        read["m3"] == [ClusterShareRate(sharePerMille: 667, decodeTokensPerSecond: 4e6 / 56_600)]
            && read["m5"] == [ClusterShareRate(sharePerMille: 333, decodeTokensPerSecond: 4e6 / 21_900)] && read["m9"] == nil
            && history.artifacts[artifact]?["m3"]?.points.first?.probe.windowStepMicroseconds == 56_600)
    // c40 on the pair: per token the M3 Ultra is faster (3:2 by plain steps), per window the M5 Max is: a load that
    // serves the head balances its windows.
    let c40 = ClusterShareProbeHistory().recording([
        .init(member: "m3", buildSHA256: build, probe: probe(600, 31_300, window: 51_900)),
        .init(member: "m5", buildSHA256: build, probe: probe(400, 27_000, window: 33_000))], artifactSHA256: artifact, now: 1_000)
        .shareRates(artifactSHA256: artifact, members: ["m3", "m5"], now: 2_000)
    let perWindow = { (rates: [ClusterShareRate]?) in rates.map { $0[0].decodeTokensPerSecond * Double($0[0].sharePerMille) / 1000 } ?? 0 }
    checks.require("share probe history: a head-serving load's rates follow its windows (the M5's whole-model window rate is the higher)",
        perWindow(c40["m5"]) > perWindow(c40["m3"]))
    let plainOnly = ClusterShareProbeHistory().recording([.init(member: "m3", buildSHA256: build, probe: probe(600, 31_300))],
        artifactSHA256: artifact, now: 1_000).shareRates(artifactSHA256: artifact, member: "m3", now: 2_000)
    checks.require("share probe history: a load without the head keeps one over its plain step",
        plainOnly == [ClusterShareRate(sharePerMille: 600, decodeTokensPerSecond: 1e6 / 31_300)])
    checks.require("share probe history: another model's plan reads none",
        history.shareRates(artifactSHA256: other, members: ["m3", "m5"], now: 2_000).isEmpty)
    history = history.recording([.init(member: "m3", buildSHA256: build, probe: probe(500, 24_900))], artifactSHA256: artifact, now: 3_000)
        .recording([.init(member: "m3", buildSHA256: build, probe: probe(500, 25_100))], artifactSHA256: artifact, now: 4_000)
    let m3 = history.shareRates(artifactSHA256: artifact, member: "m3", now: 5_000)
    checks.require("share probe history: a later load adds its share ahead of the earlier ones and replaces its own share's point",
        m3.map(\.sharePerMille) == [500, 667] && m3.first?.decodeTokensPerSecond == 1e6 / 25_100)
    checks.require("share probe history: points older than 30 days or dated ahead are not used",
        history.shareRates(artifactSHA256: artifact, member: "m5", now: 1_000 + ClusterShareProbeHistory.maximumAgeSeconds + 1).isEmpty
            && history.shareRates(artifactSHA256: artifact, member: "m5", now: 1_000 - ClusterShareProbeHistory.maximumFutureSeconds - 1).isEmpty
            && history.shareRates(artifactSHA256: artifact, member: "m5", now: 1_000 + ClusterShareProbeHistory.maximumAgeSeconds).count == 1)
    let restarted = history.recording([.init(member: "m3", buildSHA256: rebuilt, probe: probe(667, 30_000))], artifactSHA256: artifact, now: 6_000)
    checks.require("share probe history: a probe from another worker build starts that member's points again; the other member's stay",
        restarted.shareRates(artifactSHA256: artifact, member: "m3", now: 6_000).map(\.sharePerMille) == [667]
            && restarted.artifacts[artifact]?["m3"]?.buildSHA256 == rebuilt
            && restarted.shareRates(artifactSHA256: artifact, member: "m5", now: 6_000).count == 1)
    checks.require("share probe history: an invalid probe, member, build or model is not recorded",
        history.recording([.init(member: "m3", buildSHA256: build, probe: probe(1_000, 24_900))], artifactSHA256: artifact, now: 7_000) == history
            && history.recording([.init(member: "", buildSHA256: build, probe: probe(500, 24_900))], artifactSHA256: artifact, now: 7_000) == history
            && history.recording([.init(member: "m3", buildSHA256: "short", probe: probe(500, 24_900))], artifactSHA256: artifact, now: 7_000) == history
            && history.recording([.init(member: "m3", buildSHA256: build, probe: probe(500, 24_900))], artifactSHA256: "A", now: 7_000) == history)
    // The bounds: the models, members of a model and shares of a member measured last.
    var full = ClusterShareProbeHistory()
    let long = String(repeating: "x", count: 100)
    for model in 0..<10 {
        for member in 0..<6 {
            for share in 0..<10 {
                full = full.recording([.init(member: "member-\(member)-\(long)", buildSHA256: build,
                        probe: probe(100 + share * 80, 10_000 + share, window: 20_000 + share))],
                    artifactSHA256: String(repeating: "0", count: 63) + String(model, radix: 16),
                    now: 1_792_775_899.275354 + Double(model * 1_000 + member * 100 + share))
            }
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(full)
    let models = Set((2..<10).map { String(repeating: "0", count: 63) + String($0, radix: 16) })
    checks.require("share probe history: at most 8 models, 4 members of each and 8 shares of each member, the ones measured last (\(encoded.count) bytes, within \(ClusterShareProbeHistory.maximumBytes))",
        Set(full.artifacts.keys) == models
            && full.artifacts.values.allSatisfy { members in
                Set(members.keys) == Set((2..<6).map { "member-\($0)-\(long)" })
                    && members.values.allSatisfy { $0.points.map(\.probe.sharePerMille) == (2..<10).reversed().map { 100 + $0 * 80 } }
            }
            && encoded.count <= ClusterShareProbeHistory.maximumBytes && ClusterShareProbeHistory.decode(encoded) == full)
    func decodes(_ change: (inout [String: Any]) -> Void) throws -> Bool {
        var object = try JSONSerialization.jsonObject(with: encoder.encode(history)) as! [String: Any]
        change(&object)
        return ClusterShareProbeHistory.decode(try JSONSerialization.data(withJSONObject: object)) != nil
    }
    func editing(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var artifacts = object["artifacts"] as! [String: Any], members = artifacts[artifact] as! [String: Any]
        var member = members["m3"] as! [String: Any]
        change(&member)
        members["m3"] = member; artifacts[artifact] = members; object["artifacts"] = artifacts
    }
    checks.require("share probe history: a file of another schema, a share twice, a probe out of bounds or a bad build is refused whole",
        try decodes { _ in } && !(try decodes { $0["schema"] = "darkbloom_cluster_link_probes_v1" })
            && !(try decodes { editing(&$0) { member in
                var points = member["points"] as! [[String: Any]]; points.append(points[0]); member["points"] = points } })
            && !(try decodes { editing(&$0) { member in
                var points = member["points"] as! [[String: Any]], first = points[0]
                var probe = first["probe"] as! [String: Any]; probe["plainStepMicroseconds"] = 0
                first["probe"] = probe; points[0] = first; member["points"] = points } })
            && !(try decodes { editing(&$0) { member in member["buildSHA256"] = "build" } })
            && ClusterShareProbeHistory.decode(Data(count: ClusterShareProbeHistory.maximumBytes + 1)) == nil)
}

/// Two constructed Macs whose indices make the M3 Ultra twice as fast at
/// decode as the M5 Max per byte (prefill alike), so that the hardware prior
/// alone places the 27B 2:1, as the product did.
private func shareProbePair(_ layout: ClusterModelLayout, link: ClusterLinkCosts,
                            m5: SyntheticMac = .idle(128)) throws -> [ClusterPlacementDevice] {
    func indexed(_ mac: SyntheticMac, _ chip: String, decode: Double) throws -> ClusterDeviceProfile {
        var profile = try mac.profile(chip: chip)
        profile.speedIndex = .init(chip: chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 500_000, decodeIndex: decode)
        try profile.validate()
        return profile
    }
    let profiles = [try indexed(.idle(256), "Apple M3 Ultra", decode: 60_000), try indexed(m5, "Apple M5 Max", decode: 30_000)]
    let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.chip, osBuild: $0.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: [], indices: profiles.compactMap(\.speedIndex))
    return ClusterHardwarePrior.absolute(zip(["m3", "m5"], zip(profiles, speeds)).map {
        ClusterPlacementDevice(label: $0.0, profile: $0.1.0, speed: $0.1.1) }, layout: layout, link: link)
}

private func checkShareProbePlans(_ layout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let link = ClusterLinkCosts(probe: measuredProbe(), measuredUTC: "2026-10-24T22:00:00Z")!
    var policy = ClusterPlacementPolicy()
    policy.promptTokens = 128; policy.outputTokens = min(128, layout.maximumOutputTokens)
    policy.modes = [.tensorParallel]; policy.leader = "m3"
    let devices = try shareProbePair(layout, link: link)
    func shares(_ result: ClusterPlacementResult) -> [Int] { result.chosen?.tensorShares ?? [1, 1] }
    func planned(_ probes: [String: [ClusterShareRate]]) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: devices.map { $0.addingShareRates(probes) }, layout: layout, policy: policy, link: link)
    }
    let afterTwoToOne = ["m3": [ClusterShareRate(sharePerMille: 667, decodeTokensPerSecond: 1e6 / 32_100)],
                         "m5": [ClusterShareRate(sharePerMille: 333, decodeTokensPerSecond: 1e6 / 17_400)]]
    let afterBoth = ["m3": [ClusterShareRate(sharePerMille: 500, decodeTokensPerSecond: 1e6 / 24_900)] + afterTwoToOne["m3"]!,
                     "m5": [ClusterShareRate(sharePerMille: 500, decodeTokensPerSecond: 1e6 / 26_100)] + afterTwoToOne["m5"]!]
    let afterEven = ["m3": [afterBoth["m3"]![0]], "m5": [afterBoth["m5"]![0]]]
    let prior = try planned([:]), first = try planned(afterTwoToOne), second = try planned(afterBoth), even = try planned(afterEven)
    checks.require("share probes: the hardware prior alone gives the M3 Ultra the larger share (\(shares(prior)))",
        prior.chosen?.mode == .tensorParallel && shares(prior)[0] > shares(prior)[1])
    checks.require("share probes: after one load at 2:1 (M3 Ultra 2/3 in 32.1 ms, M5 Max 1/3 in 17.4 ms) the next plan balances the shares 1:1 (got \(shares(first)))",
        first.chosen?.mode == .tensorParallel && shares(first) == [1, 1]
            && first.tensorParallel?.devices.allSatisfy({ $0.split.measured && $0.split.measuredSteps != nil }) == true)
    checks.require("share probes: after a load at 1:1 as well the plan stays 1:1 (got \(shares(second))); and from 1:1 alone (got \(shares(even)))",
        shares(second) == [1, 1] && shares(even) == [1, 1])
    // The chosen split's predicted step is the slower rank's measured line plus the link's reductions.
    let tp = layout.tensorParallel!
    let reductions = Double(tp.reductionsPerStep(layerCount: layout.layerCount)) * link.reduction!.seconds(bytes: tp.family.partialBytesPerToken)
    let step = max(0.0321 * 0.5 / 0.667, 0.0174 * 0.5 / 0.333) + reductions
    checks.require("share probes: the 1:1 step is the slower rank's (the M5 Max, 26.13 ms in proportion to its 1/3 probe) plus \(tp.reductionsPerStep(layerCount: layout.layerCount)) reductions",
        abs(1 / (first.chosen?.rested.decodeTokensPerSecond ?? 0) - step) < 1e-9)
    // A probe that timed decode only leaves the prefill prediction as the prior made it.
    func firstToken(_ probes: [String: [ClusterShareRate]], _ weights: [Int]?) throws -> Double {
        try ClusterPlacementPlanner.evaluate(devices: devices.map { $0.addingShareRates(probes) }, cuts: [], mode: .tensorParallel,
            prefillSchedule: layout.prefillSchedules.contains(.oneChunkLookahead) ? .oneChunkLookahead : .serial,
            layout: layout, policy: policy, link: link, tensorShares: weights).rested.firstTokenSeconds
    }
    checks.require("share probes: a decode probe changes no first-token prediction",
        try firstToken(afterBoth, [2, 1]) == firstToken([:], [2, 1]) && firstToken(afterBoth, nil) == firstToken([:], nil))
    // No probe, or another member's: the plan is the earlier planner's, byte for byte.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let others = try planned(["m9": afterTwoToOne["m3"]!])
    checks.require("share probes: without a probe of these members the plan is byte for byte the one without probes",
        try encoder.encode(others) == encoder.encode(prior)
            && encoder.encode(try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)) == encoder.encode(prior))
    // A speed known only as a ratio takes no probe (a probe's steps are seconds).
    let relative = ClusterPlacementDevice(label: "m3", profile: devices[0].profile, speed: .assumedEqual)
    checks.require("share probes: a device whose speed is only a ratio takes none",
        relative.addingShareRates(afterTwoToOne).speed == .assumedEqual)
    // The plan's words name each Mac's measured shares.
    let lines = ClusterPlacementExplanation.describe(first, devices: devices.map { $0.addingShareRates(afterTwoToOne) }, layout: layout, link: link)
    checks.require("share probes: the plan's tensor-parallel lines name each Mac's measured shares",
        lines.contains { $0.contains("m3:") && $0.contains("measured shares step 67% in 32.10 ms") }
            && lines.contains { $0.contains("m5:") && $0.contains("measured shares step 33% in 17.40 ms") })
    try checkShareProbeMemoryFirst(layout, link: link, policy: policy, probes: afterBoth, checks)
    try checkShareProbeServed(layout, link: link, policy: policy, devices: devices, probes: afterBoth, checks)
    try checkPlanToolShareProbes(layout, link: link, devices: devices, checks)
}

/// `plan` reads each device's share probes as the setup does (the saved
/// file, or `--share-probes FILE`), says so and plans on them; without them,
/// or with another model's, the plan is the one without probes.
private func checkPlanToolShareProbes(_ layout: ClusterModelLayout, link: ClusterLinkCosts, devices: [ClusterPlacementDevice],
                                      _ checks: PlacementChecks) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-probes-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    func write(_ data: Data, _ name: String) throws -> String {
        let file = scratch.appendingPathComponent(name)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }
    let layoutFile = try write(layout.encoded(), "layout.json"), linkFile = try write(JSONEncoder().encode(link), "link.json")
    let peers = try devices.flatMap { ["--peer", "\($0.label)=" + (try write($0.profile.encoded(), "\($0.label).json"))] }
    let build = String(repeating: "c", count: 64), now = Date().timeIntervalSince1970
    let recorded: [ClusterShareProbeHistory.Recorded] = [
        .init(member: "m3", buildSHA256: build, probe: .init(sharePerMille: 667, plainStepMicroseconds: 32_100, rounds: 7)),
        .init(member: "m5", buildSHA256: build, probe: .init(sharePerMille: 333, plainStepMicroseconds: 17_400, rounds: 7))]
    let file = try write(JSONEncoder().encode(ClusterShareProbeHistory().recording(recorded,
        artifactSHA256: layout.artifactSHA256, now: now - 60)), "share-probes.json")
    let other = try write(JSONEncoder().encode(ClusterShareProbeHistory().recording(recorded,
        artifactSHA256: String(repeating: "9", count: 64), now: now - 60)), "other-model.json")
    func plan(_ extra: [String], saved: String?) throws -> (shares: [Int], lines: [String]) {
        let printed = try ClusterPlacementTool.run(["plan", "--layout", layoutFile] + peers + ["--leader", "m3", "--link", linkFile,
            "--prompt-tokens", "128", "--output-tokens", "\(min(128, layout.maximumOutputTokens))", "--modes", "tensor_parallel_v1",
            "--json"] + extra, sampleDevice: { throw ProbeError("recorded profiles only") },
            savedShareProbes: saved.map(URL.init(fileURLWithPath:)))
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let chosen = (object?["result"] as? [String: Any])?["chosen"] as? [String: Any]
        return ((chosen?["tensorShares"] as? [Int]) ?? [1, 1], (object?["explanation"] as? [String]) ?? [])
    }
    let named = try plan(["--share-probes", file], saved: nil), saved = try plan([], saved: file)
    checks.require("plan tool: --share-probes FILE plans on each Mac's saved share steps (1:1) and says which",
        named.shares == [1, 1] && named.lines.first == "Share probes"
            && named.lines.contains { $0.contains("m3 67% in 32.10 ms") && $0.contains("m5 33% in 17.40 ms") })
    checks.require("plan tool: given no --share-probes it reads the setup's saved file, as the setup plans",
        saved.shares == [1, 1] && saved.lines == named.lines)
    let none = try plan([], saved: nil), foreign = try plan(["--share-probes", other], saved: nil)
    checks.require("plan tool: no saved probes, or another model's, plan as before (\(none.shares)) and say nothing of them",
        none.shares == [2, 1] && !none.lines.contains("Share probes") && foreign.shares == [2, 1]
            && foreign.lines.contains { $0.contains("holds no share probe of this model") })
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    let unread = try plan([], saved: file)
    checks.require("plan tool: a saved file others can read is not used, as the setup does not use it",
        unread.shares == [2, 1] && unread.lines.contains { $0.contains("is not used: it is not a file of this user's") })
    checks.refuses("plan tool: a named file that is not a share probe history stops the plan", because: "is not a share probe history") {
        _ = try plan(["--share-probes", linkFile], saved: nil)
    }
}

/// Memory fit still ranks first: an M5 Max that holds the 1:2 share now but
/// not the 1:1 share keeps the split that fits now, whatever its probes say.
private func checkShareProbeMemoryFirst(_ layout: ClusterModelLayout, link: ClusterLinkCosts, policy: ClusterPlacementPolicy,
                                        probes: [String: [ClusterShareRate]], _ checks: PlacementChecks) throws {
    let idle = try shareProbePair(layout, link: link)
    let schedule: ClusterPrefillSchedule = layout.prefillSchedules.contains(.oneChunkLookahead) ? .oneChunkLookahead : .serial
    func need(_ weights: [Int]?) throws -> Int {
        try ClusterPlacementPlanner.evaluate(devices: idle, cuts: [], mode: .tensorParallel, prefillSchedule: schedule,
            layout: layout, policy: policy, link: link, tensorShares: weights).ranks[1].needBytes
    }
    let small = try need([2, 1]), large = try need(nil)
    // The M5 Max's free memory, a quarter GiB at a time, until its gate admits between the two needs.
    var m5 = SyntheticMac.idle(128)
    m5.freeGiB = Double(small) / Double(gib)
    while try m5.profile().memory.admissibleNowBytes <= small, m5.freeGiB < Double(large) / Double(gib) { m5.freeGiB += 0.25 }
    let devices = try shareProbePair(layout, link: link, m5: m5).map { $0.addingShareRates(probes) }
    let admissible = devices[1].profile.memory.admissibleNowBytes
    let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
    func text(_ bytes: Int) -> String { String(format: "%.2f GiB", Double(bytes) / Double(gib)) }
    checks.require("share probes: an M5 Max admitting \(text(admissible)) now holds the 2:1 share (\(text(small))) but not the 1:1 (\(text(large))): the split that fits now is kept (got \(result.chosen?.tensorShares ?? [1, 1]))",
        small < admissible && admissible < large && result.chosen?.mode == .tensorParallel
            && result.chosen?.tensorShares.map({ $0[0] > $0[1] }) == true && result.chosen?.tier == 0)
}

/// What the pair served at 2:1 corrects every share point of both Macs by
/// one factor, so the ratio the probes measured stands and the plan stays 1:1.
private func checkShareProbeServed(_ layout: ClusterModelLayout, link: ClusterLinkCosts, policy: ClusterPlacementPolicy,
                                   devices: [ClusterPlacementDevice], probes: [String: [ClusterShareRate]],
                                   _ checks: PlacementChecks) throws {
    let probed = devices.map { $0.addingShareRates(probes) }
    let cut = ClusterServedSpeedRecords.Setup.cut([], layerCount: layout.layerCount, mode: .tensorParallel, ranks: 2, tensorShares: [2, 1])
    let entries = (0..<4).map { index in
        ClusterServedSpeedRecords.Entry(setup: .init(modelID: "m", mode: ClusterGenerationMode.tensorParallel.rawValue, cut: cut, ranks: ["m3", "m5"]),
            sample: ClusterServedSample(route: .pair, member: nil, promptTokens: 1024, outputTokens: 128,
                firstTokenSeconds: 1.39, decodeTokensPerSecond: 24.7, finishedAt: Double(1_000 + index)))
    }
    let derived = try ClusterServedCalibration.measurements(entries: entries, devices: probed, layout: layout, link: link,
        measuredUTC: "2026-10-24T22:30:00Z").measurements
    // Every point's step over its probe: one factor for all of them, on both Macs.
    var factors: [Double] = []
    for device in probed {
        guard let measurement = derived.first(where: { $0.key.chip == device.profile.chip }) else { continue }
        for point in probes[device.label] ?? [] {
            if let served = measurement.rested.tensorShareRates?.first(where: { abs($0.sharePerMille - point.sharePerMille) <= 5 }) {
                factors.append(point.decodeTokensPerSecond / served.decodeTokensPerSecond)
            }
        }
    }
    checks.require("share probes: served calibration scales every share point of both Macs by one factor (\(factors.map { String(format: "%.6f", $0) }.joined(separator: ", ")))",
        derived.count == 2 && factors.count == 4 && factors.allSatisfy { abs($0 - factors[0]) < 1e-9 } && abs(factors[0] - 1) > 1e-3)
    let speeds = ClusterSpeedEstimator.estimate(devices: probed.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: derived, indices: probed.compactMap(\.profile.speedIndex))
    let corrected = ClusterHardwarePrior.absolute(zip(probed, speeds).map {
        ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }, layout: layout, link: link)
        .map { $0.addingShareRates(probes) }
    let result = try ClusterPlacementPlanner.plan(devices: corrected, layout: layout, policy: policy, link: link)
    checks.require("share probes: after what the pair served at 2:1 the plan is still 1:1 (got \(result.chosen?.tensorShares ?? [1, 1]))",
        result.chosen?.mode == .tensorParallel && result.chosen?.tensorShares == nil)
}

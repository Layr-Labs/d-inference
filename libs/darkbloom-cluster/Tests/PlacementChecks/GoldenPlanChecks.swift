import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// One golden plan: the digest of the plan the plan tool prints by default
/// (`plan --layout L --peer mac-a=A --peer mac-b=B --leader mac-a --json`:
/// sharded deployments only, owner 2026-10-13) and its chosen sharded
/// placement in words; and the digest of the same plan under the hand-off
/// opt-in (`--hand-off-modes`), so the phase split code kept off by default
/// is still held to its output byte for byte.
struct GoldenPlanExpectation: Decodable {
    struct Rank: Decodable, Equatable { let device: String; let firstLayer: Int; let endLayer: Int; let fit: String }
    let planSHA256: String
    let handOffPlanSHA256: String
    let runtimeModelID: String
    let cut: Int
    let mode: String
    let ranks: [Rank]
}

/// Golden plans for every family. `Golden/layouts` holds each artifact's
/// layout as the plan tool read it from the artifact's own tensor headers,
/// on Mac A and on Mac B (the two reads byte-equal); `Golden/profile-*.json`
/// are both Macs' device profiles as their plan tools sampled them. The plan
/// command's own code plans each layout here, away from both Macs, and must
/// print exactly the golden plan (first printed on both Macs; reprinted by
/// this code when the default became sharded deployments only, 2026-10-14,
/// with the hand-off opt-in's plan kept beside it). The dense rows' layouts, built
/// here from retained header metadata, must equal the ones read from the
/// real headers.
///
/// `Golden/pairs/<pair>/` holds another recorded pair of Macs (its two
/// profiles and `expected.json`), planned over the same layouts: the pair
/// this check started with is the M3 Ultra + M5 Max of 2026-10-11 (the files
/// at the top), and a pair added later must be printed as its own Macs
/// printed it, with the same code.
func checkGoldenPlans(_ directory: URL, dense: (nine: ClusterModelLayout, twentySeven: ClusterModelLayout),
                      _ checks: PlacementChecks) throws {
    try checkGoldenPlanSet(profiles: directory, layouts: directory.appendingPathComponent("layouts"), label: "golden", checks)
    let pairs = directory.appendingPathComponent("pairs", isDirectory: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: pairs.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    for name in names {
        try checkGoldenPlanSet(profiles: pairs.appendingPathComponent(name, isDirectory: true),
            layouts: directory.appendingPathComponent("layouts"), label: "golden[\(name)]", checks)
    }
    try checkRetainedDenseLayouts(directory, dense: dense, checks)
    try checkIndexedPlans(directory, checks)
}

/// A fresh install has no speed measured for any model, so the planner splits
/// the M3 Ultra + M5 Ultra pair by memory alone (the golden plans above). With
/// each Mac's model-free speed index in its profile (`device --index`), the
/// planner relates the two Macs' speeds and gives the faster Mac more layers.
/// The indices here are the ratio measured on that pair on 2026-10-12 (the
/// Qwen3.5 35B A3B alone on each Mac: prefill 4,812 against 1,836 tok/s,
/// decode 90.6 against 52.1), so the check is about the planner using them,
/// not about the benchmark.
private func checkIndexedPlans(_ directory: URL, _ checks: PlacementChecks) throws {
    let pair = directory.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    guard FileManager.default.fileExists(atPath: pair.path) else { return }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var files: [String: URL] = [:]
    for (label, prefill, decode) in [("mac-a", 1_836.0, 52.1), ("mac-b", 4_812.0, 90.6)] {
        var profile = try ClusterDeviceProfile.decode(Data(contentsOf: pair.appendingPathComponent("profile-\(label).json")))
        profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: prefill, decodeIndex: decode)
        let file = scratch.appendingPathComponent("\(label).json")
        try profile.encoded().write(to: file)
        files[label] = file
    }
    let peers = ["mac-a", "mac-b"].flatMap { ["--peer", "\($0)=" + files[$0]!.path] }
    for (name, memoryCut) in [("qwen3.5-35b-a3b-2026-08-25-r1", 20), ("Qwen3.5-9B-2026-09-03-r1", 16), ("Qwen3.8-27B-4bit-mtp-2026-09-03-r1", 32)] {
        let printed = try ClusterPlacementTool.run(["plan", "--layout", directory.appendingPathComponent("layouts/\(name).json").path]
            + peers + ["--leader", "mac-a", "--hand-off-modes", "--json"], sampleDevice: { throw ProbeError("recorded profiles only") })
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let chosen = (object?["result"] as? [String: Any])?["chosen"] as? [String: Any]
        let cut = (chosen?["cuts"] as? [Int])?.first ?? -1
        let mode = chosen?["mode"] as? String ?? "-"
        let devices = (object?["devices"] as? [[String: Any]]) ?? []
        let sources = devices.compactMap { ($0["speed"] as? [String: Any])?["source"] as? String }
        checks.require("indexed[m3ultra-m5ultra] \(name): with both Macs' speed indices the M5 Ultra gets more layers than the memory-only cut \(memoryCut) (cut \(cut), \(mode)), the speeds labelled as index estimates",
            cut > 0 && cut < memoryCut && mode == "phase_split_mtp_v1" && sources.contains("transferredByDeviceIndex"))
    }
    // MiMo (156 GiB), which only the M5 Ultra of this pair holds whole: by default (sharded deployments only)
    // a pipeline or tensor parallel deployment, no request routed alone.
    let mimo = directory.appendingPathComponent("layouts/mimo-v2.6-flash-mopd-2026-09-28-r1.json").path
    let shardedPrinted = try ClusterPlacementTool.run(["plan", "--layout", mimo] + peers + ["--json"],
        sampleDevice: { throw ProbeError("recorded profiles only") })
    let shardedChosen = ((try JSONSerialization.jsonObject(with: Data(shardedPrinted.utf8)) as? [String: Any])?["result"]
        as? [String: Any])?["chosen"] as? [String: Any]
    let shardedMode = (shardedChosen?["mode"] as? String).flatMap(ClusterGenerationMode.init(rawValue:))
    checks.require("indexed[m3ultra-m5ultra] MiMo, by default: a sharded mode (\(shardedMode?.rawValue ?? "none")) and no alone route",
        shardedMode?.isSharded == true && shardedChosen?["aloneRoute"] == nil)
    // Under the hand-off opt-in the phase split would have the M5 Ultra decoding with every layer (2026-10-13:
    // 42 tok/s on the pair against 57 on the M5 Ultra alone). Its whole-model need (164.6 GiB) is more than
    // the M5 Ultra admits at rest (its unwired memory less the kernel's file-cache minimum, about 158 GiB),
    // so no phase split is planned: a pipeline with the faster M5 Ultra holding more layers, no alone route.
    let printed = try ClusterPlacementTool.run(["plan", "--layout", mimo] + peers + ["--hand-off-modes", "--json"],
        sampleDevice: { throw ProbeError("recorded profiles only") })
    let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
    let result = object?["result"] as? [String: Any]
    let chosen = result?["chosen"] as? [String: Any]
    let ranks = (chosen?["ranks"] as? [[String: Any]])?.compactMap { $0["device"] as? String } ?? []
    let cut = (chosen?["cuts"] as? [Int])?.first ?? -1
    let m5 = try ClusterDeviceProfile.decode(Data(contentsOf: files["mac-b"]!))
    let m5Alone = ((result?["alone"] as? [[String: Any]])?.first { $0["device"] as? String == "mac-b" })?["needBytes"] as? Int ?? 0
    // The recorded M5 Ultra admits the whole model now though not at rest, and a split that loads now is
    // possible (owner, 2026-10-19): under the opt-in it decodes with every layer, holding more of them.
    checks.require("indexed[m3ultra-m5ultra] MiMo, under the hand-off opt-in: the M5 Ultra admits every layer now though not at rest, so it decodes holding more layers (cut \(cut), \(ranks))",
        m5Alone > m5.atRestAdmissibleBytes && m5Alone <= m5.memory.admissibleNowBytes
            && ranks == ["mac-a", "mac-b"] && cut > 0 && cut < 24)
}

private func checkGoldenPlanSet(profiles directory: URL, layouts: URL, label: String, _ checks: PlacementChecks) throws {
    let expected = try JSONDecoder().decode([String: GoldenPlanExpectation].self,
        from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
    let families = Set(expected.values.map(\.runtimeModelID))
    checks.require("\(label) plans: 11 artifacts of 11 registered rows (Qwen dense x2, Qwen A3B x2, Bonsai, Nemotron, GPT-OSS, MiMo, Gemma 4 x3)",
        expected.count == 11 && families.count == 11)
    let peers = ["mac-a", "mac-b"].flatMap { ["--peer", "\($0)=" + directory.appendingPathComponent("profile-\($0).json").path] }
    for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
        let layoutFile = layouts.appendingPathComponent("\(name).json")
        let layout = try ClusterModelLayout.decode(Data(contentsOf: layoutFile))
        // The plan tool prints the canonical encoding and a newline.
        checks.require("\(label) \(name): the layout is canonical and names its row",
            try layout.encoded() + Data([10]) == Data(contentsOf: layoutFile) && layout.runtimeModelID == want.runtimeModelID)
        checks.require("\(label) \(name): every admitted cut is one of the stage plan's cuts", Set(layout.admittedCuts).isSubset(of: layout.structuralCuts))
        // The default plan shards (a pipeline or tensor parallel, every member holding layers), byte for byte.
        let printed = try ClusterPlacementTool.run(["plan", "--layout", layoutFile.path] + peers + ["--leader", "mac-a", "--json"],
            sampleDevice: { throw ProbeError("The golden plans take every device from a recorded profile") })
        let bytes = Data((printed + "\n").utf8)
        checks.require("\(label) \(name): by default the plan is byte-for-byte the golden sharded plan (printed \(sha256(bytes)))",
            sha256(bytes) == want.planSHA256)
        // Under the hand-off opt-in the plan tool prints the kept hand-off code's plan, byte for byte.
        let handOff = try ClusterPlacementTool.run(["plan", "--layout", layoutFile.path] + peers + ["--leader", "mac-a", "--hand-off-modes", "--json"],
            sampleDevice: { throw ProbeError("The golden plans take every device from a recorded profile") })
        let handOffBytes = Data((handOff + "\n").utf8)
        checks.require("\(label) \(name): under the hand-off opt-in the plan is byte-for-byte its golden (printed \(sha256(handOffBytes)))",
            sha256(handOffBytes) == want.handOffPlanSHA256)
        let shardedResult = (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["result"] as? [String: Any]
        let shardedChosen = shardedResult?["chosen"] as? [String: Any]
        let shardedMode = (shardedChosen?["mode"] as? String).flatMap(ClusterGenerationMode.init(rawValue:))
        let shardedRanks = (shardedChosen?["ranks"] as? [[String: Any]]) ?? []
        checks.require("\(label) \(name): by default a sharded mode (\(shardedMode?.rawValue ?? "none")) with layers on both Macs and a shard table",
            shardedMode?.isSharded == true && shardedRanks.count == 2
                && shardedRanks.allSatisfy { ($0["endLayer"] as? Int ?? 0) > ($0["firstLayer"] as? Int ?? 0) } && shardedResult?["shards"] != nil)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let result = object["result"] as? [String: Any], let chosen = result["chosen"] as? [String: Any],
              let cuts = chosen["cuts"] as? [Int], let mode = chosen["mode"] as? String,
              let ranks = chosen["ranks"] as? [[String: Any]] else {
            checks.require("\(label) \(name): a placement is chosen", false)
            continue
        }
        let got = ranks.map { rank -> GoldenPlanExpectation.Rank in
            let fit = (rank["fit"] as? String) ?? ((rank["fit"] as? [String: Any])?.keys.first ?? "?")
            return .init(device: rank["device"] as? String ?? "?", firstLayer: rank["firstLayer"] as? Int ?? -1,
                endLayer: rank["endLayer"] as? Int ?? -1, fit: fit)
        }
        checks.require("\(label) \(name): cut \(want.cut), \(want.mode), \(want.ranks.map { "\($0.device) \($0.firstLayer)-\($0.endLayer) \($0.fit)" })",
            cuts == [want.cut] && mode == want.mode && got == want.ranks && layout.admittedCuts.contains(want.cut))
    }
}

private func checkRetainedDenseLayouts(_ directory: URL, dense: (nine: ClusterModelLayout, twentySeven: ClusterModelLayout),
                                       _ checks: PlacementChecks) throws {
    // The retained metadata keeps only the tensors the runtime loads, so the
    // excluded group (vision and head tensors no range loads) is the one field
    // it cannot reproduce; every other field must be identical.
    for (name, built) in [("Qwen3.5-9B-2026-09-03-r1", dense.nine), ("Qwen3.8-27B-4bit-mtp-2026-09-03-r1", dense.twentySeven)] {
        var a = try JSONSerialization.jsonObject(with: built.encoded()) as? [String: Any] ?? [:]
        var b = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("layouts/\(name).json"))) as? [String: Any] ?? [:]
        let excludedRead = (b["excluded"] as? [String: Any])?["tensorCount"] as? Int ?? 0
        // The speculative head is a view inside the excluded group, so it goes with it.
        a["excluded"] = nil; b["excluded"] = nil; b["speculativeHead"] = nil
        // The tensor-parallel facts were derived after the golden layouts were
        // recorded on both Macs: present in the built layout, absent there.
        let tensorParallel = a.removeValue(forKey: "tensorParallel") != nil && b["tensorParallel"] == nil
        // So does the runtime's tensor-parallel mode in the row's mode list.
        if let modes = a["generationModes"] as? [String], !((b["generationModes"] as? [String]) ?? []).contains(ClusterGenerationMode.tensorParallel.rawValue) {
            a["generationModes"] = modes.filter { $0 != ClusterGenerationMode.tensorParallel.rawValue }
        }
        checks.require("golden \(name): the layout from retained header metadata equals the one read from the real headers in every field but the \(excludedRead) excluded tensors (and the tensor-parallel facts the golden predates)",
            NSDictionary(dictionary: a).isEqual(to: b) && a.count == 18 && tensorParallel)
    }
}

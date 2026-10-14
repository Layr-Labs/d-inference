import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// `pipeline_mtp_v1` (MiMo's three next-N heads on the last rank of a
/// pipeline): the last rank is charged the head and a copy of the token
/// embedding it looks drafts up in, nothing else changes, and with no measured
/// speed-up the planner keeps the plain pipeline. The MiMo layout read from the
/// artifact's real headers (golden), with the head as those headers give it
/// (42 bf16 tensors, 1,975,640,448 bytes, the largest 134,217,728) and the mode
/// the row now lists; the M3 Ultra + M5 Ultra profiles both Macs sampled.
func checkPipelineSpeculativeHolding(_ golden: URL, _ checks: PlacementChecks) throws {
    let file = golden.appendingPathComponent("layouts/mimo-v2.6-flash-mopd-2026-09-28-r1.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    object["generationModes"] = [ClusterGenerationMode.pipeline, .pipelineCompactDecode, .pipelineMTP].map(\.rawValue)
    object["speculativeHead"] = ["storedBytes": 1_975_640_448, "loadedBytes": 1_975_640_448, "largestTensorBytes": 134_217_728,
                                 "tensorCount": 42, "requestWorkBytes": 0]
    let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    let page = 16_384
    let holding = layout.speculativeHolding(mode: .pipelineMTP, pageSizeBytes: page)
    checks.require("pipeline_mtp_v1: the last rank holds the head and the embedding copy, each tensor in whole pages",
        holding.bytes == 1_975_640_448 + 42 * page + 664_010_752 + 3 * page && holding.largestTensorBytes == 624_951_296)
    checks.require("a plain pipeline holds no head; a speculative phase split holds the head without a second embedding",
        layout.speculativeHolding(mode: .pipeline, pageSizeBytes: page).bytes == 0
            && layout.speculativeHolding(mode: .phaseSplitMTP, pageSizeBytes: page).bytes == 1_975_640_448 + 42 * page)
    let held = ClusterPlacementHoldings.weightsBytes(layout: layout, boundaries: [47], mode: .pipelineMTP, pageSizeBytes: page)
    let plain = ClusterPlacementHoldings.weightsBytes(layout: layout, boundaries: [47], mode: .pipeline, pageSizeBytes: page)
    checks.require("at cut 47 only rank 1 holds more, by exactly that charge",
        held[0] == plain[0] && held[1] == plain[1] + holding.bytes)

    // The planner, given the mode and no measured speed-up, keeps the plain pipeline on this pair.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-mtp-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let edited = scratch.appendingPathComponent("mimo.json")
    try layout.encoded().write(to: edited)
    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    let peers = ["mac-a", "mac-b"].flatMap { ["--peer", "\($0)=" + pair.appendingPathComponent("profile-\($0).json").path] }
    func chosen(_ extra: [String]) throws -> (mode: String, ranks: [[String: Any]]) {
        let printed = try ClusterPlacementTool.run(["plan", "--layout", edited.path] + peers + ["--json"] + extra,
            sampleDevice: { throw ProbeError("recorded profiles only") })
        let value = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let chosen = (value?["result"] as? [String: Any])?["chosen"] as? [String: Any]
        return (chosen?["mode"] as? String ?? "-", chosen?["ranks"] as? [[String: Any]] ?? [])
    }
    let free = try chosen([])
    checks.require("with no measured speed-up the planner keeps a plain pipeline mode for MiMo (chose \(free.mode))",
        free.mode == ClusterGenerationMode.pipeline.rawValue || free.mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)
    let forced = try chosen(["--modes", ClusterGenerationMode.pipelineMTP.rawValue])
    checks.require("asked for pipeline_mtp_v1 alone, the planner places it and charges the last rank (chose \(forced.mode))",
        forced.mode == ClusterGenerationMode.pipelineMTP.rawValue && forced.ranks.count == 2)
    // The served records below are of the placement the planner chooses here (its cut and order),
    // whichever that is on these profiles: credit is only ever for the same placement.
    let placedRanks = free.ranks.compactMap { $0["device"] as? String }
    let placedCut = free.ranks.map { "\($0["firstLayer"] as? Int ?? -1)-\($0["endLayer"] as? Int ?? -1)" }.joined(separator: "|")
    let decodingDevice = placedRanks.last ?? "-"

    // Credit from served records only: the same placement served plainly and with rounds; the
    // speed-up rides on the decoding rank and the planner then prefers the rounds, or does not.
    func served(rounds: Double) throws -> URL {
        func entries(_ mode: ClusterGenerationMode, _ decode: Double) -> [ClusterServedSpeedRecords.Entry] {
            (0..<3).map { index in
                .init(setup: .init(modelID: layout.runtimeModelID, mode: mode.rawValue, cut: placedCut, ranks: placedRanks),
                      sample: .init(route: .pair, member: nil, promptTokens: 4096, outputTokens: 64, firstTokenSeconds: 3.7,
                                    decodeTokensPerSecond: decode + Double(index) * 0.1, finishedAt: 1_760_000_000 + Double(index)))
            }
        }
        let file = scratch.appendingPathComponent("served-\(rounds).json")
        try ClusterServedSpeedRecords(entries: entries(.pipeline, 41.6) + entries(.pipelineMTP, rounds)).encoded().write(to: file)
        return file
    }
    func planned(rounds: Double) throws -> (mode: String, decode: Double, explanation: String) {
        let printed = try ClusterPlacementTool.run(["plan", "--layout", edited.path] + peers
            + ["--served", try served(rounds: rounds).path, "--json"], sampleDevice: { throw ProbeError("recorded profiles only") })
        let value = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let chosen = (value?["result"] as? [String: Any])?["chosen"] as? [String: Any]
        let rested = chosen?["rested"] as? [String: Any]
        return (chosen?["mode"] as? String ?? "-", rested?["decodeTokensPerSecond"] as? Double ?? 0,
                (value?["explanation"] as? [String] ?? []).joined(separator: "\n"))
    }
    let faster = try planned(rounds: 55.6), slower = try planned(rounds: 38.0)
    checks.require("served rounds 1.34x the plain pipeline: the planner chooses pipeline_mtp_v1 (chose \(faster.mode), decode \(faster.decode))",
        faster.mode == ClusterGenerationMode.pipelineMTP.rawValue && faster.explanation.contains("speed-up 1.34 credited to \(decodingDevice)"))
    checks.require("served rounds slower than plain: the planner keeps a plain pipeline mode (chose \(slower.mode))",
        slower.mode == ClusterGenerationMode.pipeline.rawValue || slower.mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)
    checks.require("the credited prediction is the plain one scaled by the measured speed-up",
        abs(faster.decode / max(1e-9, try planned(rounds: 41.7).decode) - 55.7 / 41.7) < 0.05)

    // The served speed-up is recorded as the pipeline's own figure on the decoding rank, never as that
    // Mac's rate with the head (which a phase split or the Mac alone would then be credited with).
    do {
        let profiles = try ["mac-a", "mac-b"].map { label in
            ClusterPlacementDevice(label: label, profile: try ClusterDeviceProfile.decode(
                Data(contentsOf: pair.appendingPathComponent("profile-\(label).json"))),
                speed: ClusterDeviceSpeed(source: .measured, absolute: true,
                    rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 40), sustained: nil, explanation: "constructed"))
        }
        let entries = try ClusterServedSpeedRecords.decode(Data(contentsOf: try served(rounds: 55.6))).entries
        let derived = try ClusterServedCalibration.measurements(entries: entries, devices: profiles, layout: layout,
            link: .unmeasured, measuredUTC: "2026-10-14T00:00:00Z").measurements
        let decoder = (profiles.first { $0.label == decodingDevice } ?? profiles[0]).profile
        let own = derived.filter { $0.key.chip == decoder.chip && $0.key.osBuild == decoder.osBuild }
        checks.require("the decoding rank's served record carries the rounds' speed-up as its own figure, no head rate",
            !own.isEmpty && own.allSatisfy { $0.rested.speculativeDecodeTokensPerSecond == nil }
                && own.contains { abs(($0.rested.pipelineSpeculativeFactor ?? 0) - 55.7 / 41.7) < 0.01 })
    }

    // Rounds served without the same placement ever serving plainly: nothing measured says what the
    // rounds gained, so nothing is credited (the plain prediction is no measurement).
    do {
        let file = scratch.appendingPathComponent("served-rounds-only.json")
        try ClusterServedSpeedRecords(entries: (0..<3).map { index in
            .init(setup: .init(modelID: layout.runtimeModelID, mode: ClusterGenerationMode.pipelineMTP.rawValue,
                               cut: placedCut, ranks: placedRanks),
                  sample: .init(route: .pair, member: nil, promptTokens: 4096, outputTokens: 64, firstTokenSeconds: 3.7,
                                decodeTokensPerSecond: 58 + Double(index) * 0.1, finishedAt: 1_760_000_000 + Double(index)))
        }).encoded().write(to: file)
        let printed = try ClusterPlacementTool.run(["plan", "--layout", edited.path] + peers + ["--served", file.path, "--json"],
            sampleDevice: { throw ProbeError("recorded profiles only") })
        let value = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let mode = ((value?["result"] as? [String: Any])?["chosen"] as? [String: Any])?["mode"] as? String ?? "-"
        checks.require("rounds served with no plain record of the same placement earn no credit (chose \(mode))",
            mode == ClusterGenerationMode.pipeline.rawValue || mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)
    }

    // A rate with the head measured on one Mac alone (a staged reference's MTP run, or a phase split's
    // decoding rank) says nothing about a pipeline's rounds, where every rank verifies the window.
    do {
        let alone = ClusterSpeedRates(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 40, speculativeDecodeTokensPerSecond: 64)
        checks.require("a head rate measured alone is no pipeline speed-up",
            ClusterSpeculativeCredit.pipelineFactor(alone) == nil)
        let three = ClusterDeviceSpeed(source: .measured, absolute: true, rested: alone, sustained: nil,
            explanation: "constructed: this Mac's head measured alone")
        let five = ClusterDeviceSpeed(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 1250, decodeTokensPerSecond: 57), sustained: nil, explanation: "constructed")
        let macs = [try SyntheticMac.idle(256).device("mac-a", speed: three, chip: "Apple M3 Ultra"),
                    try SyntheticMac.idle(256).device("mac-b", speed: five, chip: "Apple M5 Ultra")]
        let result = try ClusterPlacementPlanner.plan(devices: macs, layout: layout)
        checks.require("a head rate measured alone never puts a pipeline's rounds first (chose \(result.chosen?.mode.rawValue ?? "-"))",
            result.chosen.map { !$0.mode.usesSpeculativeHead } ?? false)
    }
}

/// `pipeline_mtp_v1` for the Qwen 27B (its inline head under `mtp.` on the
/// last rank, beside a copy of the token embedding): the layout read from the
/// artifact's real headers (golden) now lists the mode; the last rank is
/// charged exactly the head and the embedding copy; with no measured speed-up
/// the planner keeps the plain pipeline, and only the same placement's served
/// records (plain and with rounds) credit the rounds. Phase split modes are
/// left out of the planner's choice here, as the owner's sharded-only default does.
func checkQwenPipelineSpeculative(_ golden: URL, _ checks: PlacementChecks) throws {
    let file = golden.appendingPathComponent("layouts/Qwen3.8-27B-4bit-mtp-2026-09-03-r1.json")
    let layout = try ClusterModelLayout.decode(Data(contentsOf: file))
    let page = 16_384
    checks.require("27B: the row lists pipeline_mtp_v1 beside the phase split's head mode",
        layout.generationModes.contains(.pipelineMTP) && layout.generationModes.contains(.phaseSplitMTP))
    let head = 238_930_944 + 31 * page, embedding = 715_161_600 + 3 * page
    let holding = layout.speculativeHolding(mode: .pipelineMTP, pageSizeBytes: page)
    checks.require("27B pipeline_mtp_v1: the last rank holds the head (31 tensors) and the embedding copy (3), in whole pages",
        holding.bytes == head + embedding && holding.largestTensorBytes == 635_699_200)
    let held = ClusterPlacementHoldings.weightsBytes(layout: layout, boundaries: [8], mode: .pipelineMTP, pageSizeBytes: page)
    let plain = ClusterPlacementHoldings.weightsBytes(layout: layout, boundaries: [8], mode: .pipeline, pageSizeBytes: page)
    checks.require("27B at cut 8: only the last rank holds more, by exactly that charge",
        held[0] == plain[0] && held[1] == plain[1] + holding.bytes)

    let pair = golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)
    let peers = ["mac-a", "mac-b"].flatMap { ["--peer", "\($0)=" + pair.appendingPathComponent("profile-\($0).json").path] }
    let sharded = ["--modes", [ClusterGenerationMode.pipeline, .pipelineCompactDecode, .pipelineMTP].map(\.rawValue).joined(separator: ",")]
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-pipeline-mtp-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    func plan(_ extra: [String]) throws -> (mode: String, explanation: String) {
        let printed = try ClusterPlacementTool.run(["plan", "--layout", file.path] + peers + sharded + ["--json"] + extra,
            sampleDevice: { throw ProbeError("recorded profiles only") })
        let value = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        let chosen = (value?["result"] as? [String: Any])?["chosen"] as? [String: Any]
        return (chosen?["mode"] as? String ?? "-", (value?["explanation"] as? [String] ?? []).joined(separator: "\n"))
    }
    let free = try plan([])
    checks.require("27B, sharded modes, nothing measured: the planner keeps a plain pipeline mode (chose \(free.mode))",
        free.mode == ClusterGenerationMode.pipeline.rawValue || free.mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)
    func served(plain: Double, rounds: Double) throws -> URL {
        func entries(_ mode: ClusterGenerationMode, _ decode: Double) -> [ClusterServedSpeedRecords.Entry] {
            (0..<3).map { index in
                .init(setup: .init(modelID: layout.runtimeModelID, mode: mode.rawValue, cut: "0-8|8-64", ranks: ["mac-a", "mac-b"]),
                      sample: .init(route: .pair, member: nil, promptTokens: 1024, outputTokens: 64, firstTokenSeconds: 1.0,
                                    decodeTokensPerSecond: decode + Double(index) * 0.1, finishedAt: 1_760_000_000 + Double(index)))
            }
        }
        let url = scratch.appendingPathComponent("served-\(plain)-\(rounds).json")
        try ClusterServedSpeedRecords(entries: entries(.pipeline, plain) + entries(.pipelineMTP, rounds)).encoded().write(to: url)
        return url
    }
    let faster = try plan(["--served", try served(plain: 30.0, rounds: 45.0).path])
    checks.require("27B: the same placement served 1.5x faster with rounds: the planner chooses pipeline_mtp_v1 (chose \(faster.mode))",
        faster.mode == ClusterGenerationMode.pipelineMTP.rawValue && faster.explanation.contains("credited to mac-b"))
    let slower = try plan(["--served", try served(plain: 30.0, rounds: 27.0).path])
    checks.require("27B: rounds served slower than plain: the planner keeps a plain pipeline mode (chose \(slower.mode))",
        slower.mode == ClusterGenerationMode.pipeline.rawValue || slower.mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)

    // Before this pair has served anything: a passing qualification record of the rounds that measured
    // them faster than the plain pipeline credits them (owner rule: on by default where lossless and
    // measured faster); a figure at or below 1 credits nothing that wins; this pair's own served
    // figure replaces the record's. Constructed speeds on both recorded profiles.
    do {
        func device(_ label: String, decode: Double, served: Double? = nil) throws -> ClusterPlacementDevice {
            ClusterPlacementDevice(label: label, profile: try ClusterDeviceProfile.decode(
                Data(contentsOf: pair.appendingPathComponent("profile-\(label).json"))),
                speed: ClusterDeviceSpeed(source: .measured, absolute: true,
                    rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: decode, pipelineSpeculativeFactor: served),
                    sustained: nil, explanation: "constructed"))
        }
        func chosen(recorded: Double?, served: Double? = nil) throws -> (mode: ClusterGenerationMode?, decode: Double) {
            var policy = ClusterPlacementPolicy()
            policy.modes = [.pipeline, .pipelineCompactDecode, .pipelineMTP]
            policy.recordedPipelineSpeculativeFactor = recorded
            // A served figure is the decoding Mac's own: given to both, whichever decodes.
            let result = try ClusterPlacementPlanner.plan(devices: [try device("mac-a", decode: 30, served: served),
                try device("mac-b", decode: 40, served: served)], layout: layout, policy: policy)
            return (result.chosen?.mode, result.chosen?.rested.decodeTokensPerSecond ?? 0)
        }
        let none = try chosen(recorded: nil), recorded = try chosen(recorded: 1.84)
        checks.require("27B, nothing served, no record measured the rounds: a plain pipeline mode (chose \(none.mode?.rawValue ?? "-"))",
            none.mode.map { !$0.usesSpeculativeHead } ?? false)
        checks.require("27B, nothing served, a passing record measured the rounds 1.84x: pipeline_mtp_v1 is chosen by default "
            + "(chose \(recorded.mode?.rawValue ?? "-"), decode \(recorded.decode) vs \(none.decode))",
            recorded.mode == .pipelineMTP && recorded.decode > none.decode * 1.5)
        let slower = try chosen(recorded: 0.9)
        checks.require("27B, a record that measured the rounds slower: a plain pipeline mode (chose \(slower.mode?.rawValue ?? "-"))",
            slower.mode.map { !$0.usesSpeculativeHead } ?? false)
        let overruled = try chosen(recorded: 1.84, served: 0.9)
        checks.require("27B, this pair served the rounds slower than plain: its own figure overrules the record's "
            + "(chose \(overruled.mode?.rawValue ?? "-"))", overruled.mode.map { !$0.usesSpeculativeHead } ?? false)
        checks.require("the record's figure is used only without a served one, and never as a head rate",
            ClusterSpeculativeCredit.pipelineFactor(.init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1), recorded: 1.84) == 1.84
                && ClusterSpeculativeCredit.pipelineFactor(.init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1,
                    pipelineSpeculativeFactor: 0.9), recorded: 1.84) == 0.9
                && ClusterSpeculativeCredit.pipelineFactor(.init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1,
                    speculativeDecodeTokensPerSecond: 80), recorded: nil) == nil)
    }
}

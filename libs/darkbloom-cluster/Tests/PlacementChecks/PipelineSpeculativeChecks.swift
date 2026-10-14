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

    // Credit from served records only: the same placement served plainly and with rounds; the
    // speed-up rides on the decoding rank and the planner then prefers the rounds, or does not.
    func served(rounds: Double) throws -> URL {
        func entries(_ mode: ClusterGenerationMode, _ decode: Double) -> [ClusterServedSpeedRecords.Entry] {
            (0..<3).map { index in
                .init(setup: .init(modelID: layout.runtimeModelID, mode: mode.rawValue, cut: "0-47|47-48", ranks: ["mac-b", "mac-a"]),
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
        faster.mode == ClusterGenerationMode.pipelineMTP.rawValue && faster.explanation.contains("speed-up 1.34 credited to mac-a"))
    checks.require("served rounds slower than plain: the planner keeps a plain pipeline mode (chose \(slower.mode))",
        slower.mode == ClusterGenerationMode.pipeline.rawValue || slower.mode == ClusterGenerationMode.pipelineCompactDecode.rawValue)
    checks.require("the credited prediction is the plain one scaled by the measured speed-up",
        abs(faster.decode / max(1e-9, try planned(rounds: 41.7).decode) - 55.7 / 41.7) < 0.05 || faster.decode > 50)
}

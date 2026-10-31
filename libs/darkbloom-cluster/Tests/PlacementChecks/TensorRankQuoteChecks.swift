import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Rank-priced native ledgers (`ClusterPlacementTensorRankQuote`): each rank
/// is charged what it reserves under the split being placed, and a split is
/// kept for a later widening by each rank's own growth. Constructed figures;
/// the Runtime suite checks the real per-rank derivation.
func checkTensorRankQuotes(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let original = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let layout = try executing(original, [.tensorParallel])
    let options = layout.tensorParallel!.family.shareOptions ?? []
    checks.require("TP rank quote: the 27B accepts unequal splits to price", !options.isEmpty)
    let request = try ClusterPlacementRequestScope(runtimeModelID: layout.runtimeModelID,
        artifactSHA256: layout.artifactSHA256, configurationSHA256: layout.configurationSHA256,
        promptTokens: 1024, outputTokens: 128, maximumPromptTokens: 32768, maximumOutputTokens: 32768,
        maximumContextTokens: 65536, requestChargeEveryRankBytes: 4 * gib)
    // Constructed ledger: the per-lane state divides by each rank's weight,
    // half of the shared workspace stays on every rank.
    let perLane = 24 * gib, shared = 16 * gib
    func rankBytes(_ split: [Int], _ rank: Int, _ lanes: Int) -> Int {
        split[rank] * lanes * perLane / split.reduce(0, +) + shared / 2
    }
    func quote(_ lanes: Int, ranked: Bool = true) throws -> ClusterPlacementTensorBatchQuote {
        let payload = max(512 * layout.tensorParallel!.family.partialBytesPerToken, lanes * 248320 * 4)
        return try .init(request: request, lanes: lanes, chunkTokens: 128, perLaneStateBytes: perLane,
            sharedBytesExcludingCollectives: shared, allowance: .init(maximumContextTokens: 65536,
                maximumChunkTokens: 512, requestBytesExcludingCollectives: lanes * perLane + shared,
                maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: payload + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }),
            rankQuotes: ranked ? ([[1, 1]] + options).map { split in
                .init(shares: split, requestBytesExcludingCollectives: [rankBytes(split, 0, lanes), rankBytes(split, 1, lanes)])
            } : nil)
    }
    func singleton(_ value: ClusterPlacementTensorBatchQuote, widening: ClusterPlacementTensorBatchQuote? = nil) throws -> ClusterPlacementPolicy {
        var p = ClusterPlacementPolicy(); p.leader = "a"
        p.promptTokens = request.promptTokens; p.outputTokens = request.outputTokens
        try value.applySingleton(to: &p, layout: layout)
        p.tensorParallelWideningQuote = widening
        return p
    }
    func speed(_ shardDecode: Double) -> ClusterDeviceSpeed {
        ClusterDeviceSpeed(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
                tensorShardPrefillTokensPerSecond: 1500, tensorShardDecodeTokensPerSecond: shardDecode),
            sustained: nil, explanation: "constructed CPU rates")
    }
    let link = linkCosts(reductionMicroseconds: 1)
    let one = try quote(1), two = try quote(2)
    let idle = try [SyntheticMac.idle(256).device("a", speed: speed(200)), SyntheticMac.idle(128).device("b", speed: speed(400))]

    // Pricing: every rank is charged its own split's reservation.
    let scratch = one.allowance.collectiveScratchBytes
    checks.require("TP rank quote: equal or missing weights read the equal split",
        one.rankReservedBytes(rank: 1, shares: nil) == rankBytes([1, 1], 1, 1) + scratch
            && one.rankReservedBytes(rank: 1, shares: [2, 2]) == one.rankReservedBytes(rank: 1, shares: [1, 1]))
    let unranked = try quote(1, ranked: false)
    checks.require("TP rank quote: an unquoted split or rank prices nothing",
        one.rankReservedBytes(rank: 0, shares: [5, 7]) == nil && one.rankReservedBytes(rank: 2, shares: nil) == nil
            && unranked.rankReservedBytes(rank: 0, shares: nil) == nil)
    for split in [[1, 1]] + options {
        let candidate = try ClusterPlacementPlanner.evaluate(devices: idle, cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: layout, policy: singleton(one), link: link,
            tensorShares: split == [1, 1] ? nil : split)
        checks.require("TP rank quote \(split): each rank's request is its own reservation, headroom once",
            zip(candidate.ranks.indices, idle).allSatisfy { index, device in
                candidate.ranks[index].requestNeedBytes
                    == rankBytes(split, index, 1) + scratch + device.profile.memory.loadingHeadroomBytes
            })
        let whole = try ClusterPlacementPlanner.evaluate(devices: idle, cuts: [], mode: .tensorParallel,
            prefillSchedule: .serial, layout: layout, policy: singleton(unranked), link: link,
            tensorShares: split == [1, 1] ? nil : split)
        checks.require("TP rank quote \(split): no rank is charged more than the whole-model quote",
            zip(candidate.ranks, whole.ranks).allSatisfy { $0.needBytes <= $1.needBytes && $0.weightsBytes == $1.weightsBytes })
    }

    // Strict wire form: a rank never reserves more than the whole model, each
    // split once, the equal split always present, no unknown fields.
    checks.require("TP rank quote: encode/decode preserves every rank figure",
        try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(two)) == two)
    for (name, mutate) in [
        ("rank above the whole model", { (x: inout [[String: Any]]) in x[0]["requestBytesExcludingCollectives"] = [2 * perLane + shared + 1, 1] }),
        ("zero rank", { (x: inout [[String: Any]]) in x[0]["requestBytesExcludingCollectives"] = [0, 1] }),
        ("three ranks", { (x: inout [[String: Any]]) in x[0]["requestBytesExcludingCollectives"] = [1, 1, 1] }),
        ("duplicate split", { (x: inout [[String: Any]]) in x.append(x[1]) }),
        ("missing equal split", { (x: inout [[String: Any]]) in x.removeFirst() }),
        ("equal split spelled twice over", { (x: inout [[String: Any]]) in x[0]["shares"] = [2, 2] }),
        ("unknown field", { (x: inout [[String: Any]]) in x[0]["measured"] = true }),
    ] {
        checks.refuses("TP rank quote: decoded \(name) refuses", because: "rank quote") {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(two)) as! [String: Any]
            var entries = object["rankQuotes"] as! [[String: Any]]
            mutate(&entries); object["rankQuotes"] = entries
            _ = try ClusterPlacementTensorBatchQuote.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    // Widening: on a busy second Mac, the fastest split cannot grow there,
    // a split giving that Mac fewer heads can. Thresholds come from the
    // planner's own figures on an unconstrained Mac of the same size.
    let fastest = try ClusterPlacementPlanner.plan(devices: idle, layout: layout, policy: singleton(one), link: link).chosen
    let best = fastest?.tensorShares ?? [1, 1]
    checks.require("TP rank quote: a split gives the second Mac fewer heads than the fastest one",
        options.contains { $0[1] * best[0] < best[1] * $0[0] })
    func growth(_ split: [Int], _ rank: Int) -> Int {
        (two.rankReservedBytes(rank: rank, shares: split) ?? 0) - (one.rankReservedBytes(rank: rank, shares: split) ?? 0)
    }
    var threshold: [[Int]: Int] = [:], need: [[Int]: Int] = [:]
    for split in [[1, 1]] + options {
        let rank = try ClusterPlacementPlanner.evaluate(devices: idle, cuts: [], mode: .tensorParallel, prefillSchedule: .serial,
            layout: layout, policy: singleton(one), link: link, tensorShares: split == [1, 1] ? nil : split).ranks[1]
        // The running owner keeps its weights and its own request while the
        // replacement is previewed.
        threshold[split] = rank.weightsBytes + (one.rankReservedBytes(rank: 1, shares: split) ?? 0)
            + rank.needBytes + growth(split, 1)
        need[split] = rank.needBytes
    }
    let floor = max(threshold.values.min()!, need[best]!)
    checks.require("TP rank quote: some split can widen where the fastest cannot", floor < threshold[best]!)
    let target = floor + (threshold[best]! - floor) / 2
    func busy(_ admissible: Int) throws -> ClusterPlacementDevice {
        try SyntheticMac(physicalGiB: 128, freeGiB: Double(admissible) / Double(gib), inactiveCacheGiB: 0).device("b", speed: speed(400))
    }
    let probe = try busy(target)
    let constrained = try busy(target - (probe.profile.memory.admissibleNowBytes - target))
    let admitted = constrained.profile.memory.admissibleNowBytes
    checks.require("TP rank quote: the busy Mac admits between the widenable and the fastest split's peaks",
        admitted >= floor && admitted < threshold[best]!)
    let devices = [idle[0], constrained]
    let narrow = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: singleton(one), link: link).chosen
    let widened = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: singleton(one, widening: two), link: link).chosen
    let kept = widened?.tensorShares ?? [1, 1]
    checks.require("TP rank quote: without a widening quote the fastest fitting split serves",
        narrow?.mode == .tensorParallel && (narrow?.tensorShares ?? [1, 1]) == best)
    checks.require("TP rank quote: a widening quote keeps a split the busy Mac can grow by its own growth",
        widened?.mode == .tensorParallel && kept != best && kept[1] * best[0] < best[1] * kept[0]
            && widened!.ranks.enumerated().allSatisfy { index, rank in
                rank.fit == .now && rank.weightsBytes + (one.rankReservedBytes(rank: index, shares: kept) ?? 0)
                    + rank.needBytes + growth(kept, index) <= rank.admissibleNowBytes
            })
}

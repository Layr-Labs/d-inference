import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Per-request routes and speed records from served requests, on constructed
/// Macs of several generations and sizes. The speeds below are inputs of a
/// check, not claims about any machine; the code under test names no chip.
/// The alone route and the phase split it rides on are off by default
/// (sharded deployments only, 2026-10-13); these checks hold the kept code
/// to its behaviour under the explicit opt-in (`handOffModes`, `aloneRoute`).
func checkRequestRoutes(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let nine = try layoutWithHead(inputs.nine, bytes: 136_881_152, count: 31)
    func plan(_ devices: [ClusterPlacementDevice], _ layout: ClusterModelLayout, modes: [ClusterGenerationMode]? = nil) throws
        -> (setup: ClusterRequestRouter.Setup, result: ClusterPlacementResult) {
        var policy = ClusterPlacementPolicy(); policy.modes = modes; policy.handOffModes = true
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        guard let chosen = result.chosen else { throw ClusterPlacementError("constructed pair has no placement") }
        let ordered = chosen.ranks.map { rank in devices.first { $0.label == rank.device }! }
        return (.init(devices: ordered, cuts: chosen.cuts, mode: chosen.mode, schedule: chosen.prefillSchedule, layout: layout,
                      aloneRoute: true), result)
    }
    let chunk = nine.maximumChunkTokens

    // Two equal older Macs (2 x 64 GB M1 Max): two always beat one once the
    // prompt fills more than one chunk; a one-chunk prompt cannot overlap.
    do {
        let speed = measured(prefill: 600, decode: 40)
        let macs = [try SyntheticMac.idle(64).device("m1max-a", speed: speed, chip: "Apple M1 Max"),
                    try SyntheticMac.idle(64).device("m1max-b", speed: speed, chip: "Apple M1 Max")]
        let free = try plan(macs, nine)
        if !free.setup.mode.isPhaseSplit {
            let route = try ClusterRequestRouter.decide(free.setup, promptTokens: 64, outputTokens: 64)
            checks.require("2x M1 Max: a placement no member holds whole serves every request as the pair",
                route.path == .pair && route.aloneCandidate == nil && route.aloneSeconds == nil)
        }
        let split = try plan(macs, nine, modes: [.phaseSplit])
        let short = try ClusterRequestRouter.decide(split.setup, promptTokens: chunk / 4, outputTokens: 64)
        let long = try ClusterRequestRouter.decide(split.setup, promptTokens: 16 * chunk, outputTokens: 64)
        checks.require("2x M1 Max phase split: a one-chunk prompt is no faster on the pair, so the decoding member serves it alone",
            short.path == .alone && short.member == split.setup.devices.last?.label)
        checks.require("2x M1 Max phase split: a long prompt goes to the pair, predicted much faster than one Mac",
            long.path == .pair && (long.aloneSeconds ?? 0) > 1.3 * long.pairSeconds)
        let crossover = try ClusterRequestRouter.crossoverPromptTokens(split.setup, outputTokens: 64, maximumPrompt: 32_768)
        checks.require("2x M1 Max: the pair is chosen from a few chunks of prompt on",
            crossover.map { $0 > chunk && $0 <= 4 * chunk } ?? false)
    }

    // A strong Mac with a small old one (M2 Ultra 192 GB + M1 16 GB): the pair
    // is never faster for a model the strong Mac holds, so it serves alone at
    // every prompt length; a model only the pair has room for always pairs.
    do {
        let ultra = try SyntheticMac.idle(192).device("m2ultra", speed: measured(prefill: 1_500, decode: 60), chip: "Apple M2 Ultra")
        let small = try SyntheticMac.idle(16).device("m1", speed: measured(prefill: 150, decode: 12), chip: "Apple M1")
        let split = try plan([ultra, small], nine, modes: [.phaseSplit])
        checks.require("M2 Ultra + M1: the strong Mac decodes", split.setup.devices.last?.label == "m2ultra")
        let decisions = try [64, chunk, 4 * chunk, 16 * chunk].map {
            try ClusterRequestRouter.decide(split.setup, promptTokens: $0, outputTokens: 128)
        }
        checks.require("M2 Ultra + M1: every request is served by the M2 Ultra alone (never slower than the strong Mac)",
            decisions.allSatisfy { $0.path == .alone && $0.member == "m2ultra" && ($0.aloneSeconds ?? .infinity) <= $0.pairSeconds })
        checks.require("M2 Ultra + M1: no prompt length makes the pair worth it",
            try ClusterRequestRouter.crossoverPromptTokens(split.setup, outputTokens: 128, maximumPrompt: 32_768) == nil)
        // Capacity: 60 layers of 2.5 GiB, more than either Mac holds at rest, pipeline only.
        let huge = try syntheticLayout(layers: 60, layerGiB: 2.5, modes: [.pipeline])
        let big = try SyntheticMac.idle(192).device("m2ultra", speed: measured(prefill: 300, decode: 10), chip: "Apple M2 Ultra")
        let other = try SyntheticMac.idle(128).device("m1ultra", speed: measured(prefill: 150, decode: 6), chip: "Apple M1 Ultra")
        let capacity = try plan([big, other], huge)
        let route = try ClusterRequestRouter.decide(capacity.setup, promptTokens: 32, outputTokens: 16)
        let always = try ClusterRequestRouter.crossoverPromptTokens(capacity.setup, outputTokens: 16, maximumPrompt: 8_192)
        checks.require("a capacity model (no Mac holds it alone at rest) always goes to the pair, whatever the prompt",
            capacity.result.alone.allSatisfy { a in a.needBytes > [big, other].first { $0.label == a.device }!.profile.atRestAdmissibleBytes }
                && route.path == .pair && route.aloneCandidate == nil && always == 1)
    }

    // The bench's generation gap (M3 Ultra + M5 Ultra): rates in the proportion
    // the model-free index measured between such Macs (prefill ~5x, decode ~1.8x).
    let m3 = try SyntheticMac.idle(256).device("m3ultra", speed: measured(prefill: 1_000, decode: 100), chip: "Apple M3 Ultra")
    let m5 = try SyntheticMac.idle(256).device("m5ultra", speed: measured(prefill: 4_980, decode: 176), chip: "Apple M5 Ultra")
    let pair = try plan([m3, m5], nine)
    checks.require("M3 Ultra + M5 Ultra: a phase split with the head, the M5 Ultra decoding",
        pair.setup.mode == .phaseSplitMTP && pair.setup.devices.last?.label == "m5ultra")
    let short = try ClusterRequestRouter.decide(pair.setup, promptTokens: 256, outputTokens: 128)
    let long = try ClusterRequestRouter.decide(pair.setup, promptTokens: 24_576, outputTokens: 128)
    checks.require("M3 Ultra + M5 Ultra: a short prompt is served by the M5 Ultra alone (holds every layer and the head)",
        short.path == .alone && short.member == "m5ultra" && short.aloneBasis == .predicted)
    // A prediction alone never sends a request to the pair on a small margin: the strong Mac serves (and is measured)
    // until both routes served near that length; then the tie tolerance decides.
    let longGain = (long.aloneSeconds ?? 0) / long.pairSeconds - 1
    checks.require("M3 Ultra + M5 Ultra: a long prompt predicted faster on the pair by under the unmeasured margin is served alone until both are measured",
        longGain > pair.setup.tieTolerance && longGain < pair.setup.unmeasuredMargin && long.path == .alone && long.reason.contains("not both measured"))
    func sample(_ route: ClusterServedSample.Route, _ member: String?, _ prompt: Int, first: Double, total: Double) -> ClusterServedSample {
        .init(route: route, member: member, promptTokens: prompt, outputTokens: 128, firstTokenSeconds: first,
              decodeTokensPerSecond: 127 / max(0.001, total - first), finishedAt: 500)
    }
    let measuredLong = [sample(.pair, nil, 24_000, first: long.pairFirstTokenSeconds, total: long.pairSeconds),
                        sample(.alone, "m5ultra", 25_000, first: long.aloneFirstTokenSeconds!, total: long.aloneSeconds!)]
    let longMeasured = try ClusterRequestRouter.decide(pair.setup, promptTokens: 24_576, outputTokens: 128, served: measuredLong)
    checks.require("M3 Ultra + M5 Ultra: measured near that length as predicted, the long prompt goes to the pair",
        longMeasured.path == .pair && longMeasured.pairBasis == .served && longMeasured.aloneBasis == .served
            && longMeasured.reason.contains("both measured"))
    // Measured alone near the length and still predicted slower than the pair: the pair is measured there once.
    let aloneOnly = [measuredLong[1]]
    let probe = try ClusterRequestRouter.decide(pair.setup, promptTokens: 24_576, outputTokens: 128, served: aloneOnly)
    let pending = try ClusterRequestRouter.decide(pair.setup, promptTokens: 24_576, outputTokens: 128, served: aloneOnly, measuring: [23_000])
    let strict = ClusterRequestRouter.Setup(devices: pair.setup.devices, cuts: pair.setup.cuts, mode: pair.setup.mode,
        schedule: pair.setup.schedule, layout: nine, measuresPair: false, aloneRoute: true)
    let strictRoute = try ClusterRequestRouter.decide(strict, promptTokens: 24_576, outputTokens: 128, served: aloneOnly)
    checks.require("the member alone measured near a length where the pair is still predicted faster: the pair is measured there once, then not again until its record arrives",
        probe.path == .pair && probe.measuring && pending.path == .alone && !pending.measuring && strictRoute.path == .alone)
    final class Once: @unchecked Sendable { var samples: [ClusterServedSample] = [] }
    let once = Once(); once.samples = aloneOnly
    final class Clock: @unchecked Sendable { var now = 0.0 }
    let tick = Clock()
    let measuringRouter = ClusterRequestRouting(setup: pair.setup, refreshSeconds: 30, clock: { tick.now }) { once.samples }
    let firstLong = measuringRouter.route(promptTokens: 24_576, maximumOutputTokens: 128)
    let secondLong = measuringRouter.route(promptTokens: 20_000, maximumOutputTokens: 128)
    tick.now = 31   // refreshed, no pair record arrived (a warming request is not one): measured once more
    let retryLong = measuringRouter.route(promptTokens: 24_576, maximumOutputTokens: 128)
    tick.now = 62
    let exhaustedLong = measuringRouter.route(promptTokens: 24_576, maximumOutputTokens: 128)
    once.samples = measuredLong; tick.now = 93
    let thirdLong = measuringRouter.route(promptTokens: 24_576, maximumOutputTokens: 128)
    checks.require("a serving router measures the pair at most once per refresh and twice per length band, then decides from both records",
        firstLong?.measuring == true && secondLong?.path == .alone && retryLong?.measuring == true && exhaustedLong?.path == .alone
            && thirdLong?.path == .pair && thirdLong?.measuring == false)
    checks.require("measurements far from the prompt length do not count as measured near it",
        try ClusterRequestRouter.decide(pair.setup, promptTokens: 4 * chunk, outputTokens: 128, served: measuredLong).path == .alone)
    // Predictions trusted (margin = tolerance), the planner's crossover and corrections as before.
    let trusted = ClusterRequestRouter.Setup(devices: pair.setup.devices, cuts: pair.setup.cuts, mode: pair.setup.mode,
        schedule: pair.setup.schedule, layout: nine, unmeasuredMargin: 0, aloneRoute: true)
    checks.require("M3 Ultra + M5 Ultra, predictions trusted: a long prompt goes to the pair",
        try ClusterRequestRouter.decide(trusted, promptTokens: 24_576, outputTokens: 128).path == .pair)
    let crossover = try ClusterRequestRouter.crossoverPromptTokens(trusted, outputTokens: 128, maximumPrompt: 32_768)
    checks.require("M3 Ultra + M5 Ultra, predictions trusted: the crossover is a prompt of several chunks",
        crossover.map { $0 > 2 * chunk && $0 < 24_576 } ?? false)
    checks.require("the route is the same whichever Mac was listed first",
        try ClusterRequestRouter.decide(plan([m5, m3], nine).setup, promptTokens: 256, outputTokens: 128) == short)

    // Served requests correct a route's prediction: a pair whose hand-off and
    // link cost what the planner did not price loses where it was predicted to win.
    let near = (crossover ?? 6 * chunk) * 3 / 2
    let predicted = try ClusterRequestRouter.decide(trusted, promptTokens: near, outputTokens: 128)
    let slowPair = (0..<3).map { index in
        ClusterServedSample(route: .pair, member: nil, promptTokens: near + index, outputTokens: 128,
            firstTokenSeconds: predicted.pairFirstTokenSeconds * 1.6, decodeTokensPerSecond: 128 / max(0.001, predicted.pairSeconds - predicted.pairFirstTokenSeconds),
            finishedAt: Double(1_000 + index))
    }
    let corrected = try ClusterRequestRouter.decide(trusted, promptTokens: near, outputTokens: 128, served: slowPair)
    checks.require("served pair requests 60 % slower than predicted move a near-crossover prompt to the member alone (\(near) tokens)",
        predicted.path == .pair && corrected.path == .alone && corrected.pairBasis == .served && corrected.aloneBasis == .predicted)
    checks.require("the output length a route is priced at follows what the setup served, never above the request's limit",
        ClusterRequestRouter.expectedOutputTokens(maximum: 4_096, served: slowPair) == 128
            && ClusterRequestRouter.expectedOutputTokens(maximum: 64, served: slowPair) == 64
            && ClusterRequestRouter.expectedOutputTokens(maximum: 300, served: []) == 300)

    // The serving leader's router: re-reads its records, and decides like the router.
    final class Box: @unchecked Sendable { var samples: [ClusterServedSample] = []; var reads = 0; var now = 0.0 }
    let box = Box()
    let routing = ClusterRequestRouting(setup: trusted, refreshSeconds: 30, clock: { box.now }) { box.reads += 1; return box.samples }
    let first = routing.route(promptTokens: near, maximumOutputTokens: 128)
    box.samples = slowPair; box.now = 10
    let cached = routing.route(promptTokens: near, maximumOutputTokens: 128)
    box.now = 40
    let refreshed = routing.route(promptTokens: near, maximumOutputTokens: 128)
    checks.require("a serving router decides like the router, and takes new speed records at its refresh",
        first == predicted && cached == predicted && refreshed?.path == .alone && box.reads == 2
            && refreshed?.workerRoute == .decodingRankAlone && first?.workerRoute == nil)
    checks.require("a telemetry record becomes a served sample only when it computed its whole prompt and completed",
        ClusterServedSample.fromTelemetry(route: "alone:m5ultra", promptTokens: 400, cachedTokens: 0, completionTokens: 9,
            firstTokenMilliseconds: 80, decodeTokensPerSecond: 200, outcome: "stop", finishedAt: 1)?.member == "m5ultra"
            && ClusterServedSample.fromTelemetry(route: nil, promptTokens: 400, cachedTokens: 0, completionTokens: 9,
                firstTokenMilliseconds: 80, decodeTokensPerSecond: 200, outcome: "length", finishedAt: 1)?.route == .pair
            && ClusterServedSample.fromTelemetry(route: nil, promptTokens: 400, cachedTokens: 12, completionTokens: 9,
                firstTokenMilliseconds: 80, decodeTokensPerSecond: 200, outcome: "stop", finishedAt: 1) == nil
            && ClusterServedSample.fromTelemetry(route: "pair", promptTokens: 400, cachedTokens: 0, completionTokens: 9,
                firstTokenMilliseconds: 80, decodeTokensPerSecond: 200, outcome: "engine_error", finishedAt: 1) == nil)

    // Speed records from served requests, recovering absolute rates from the
    // model-free index's ratios alone (the fresh-install case, F1).
    let index3 = ClusterDeviceSpeed(source: .transferredByDeviceIndex, absolute: false,
        rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1), sustained: nil, explanation: "index reference")
    let index5 = ClusterDeviceSpeed(source: .transferredByDeviceIndex, absolute: false,
        rested: .init(prefillTokensPerSecond: 4.98, decodeTokensPerSecond: 1.76), sustained: nil, explanation: "index ratio")
    let r3 = try SyntheticMac.idle(256).device("m3ultra", speed: index3, chip: "Apple M3 Ultra")
    let r5 = try SyntheticMac.idle(256).device("m5ultra", speed: index5, chip: "Apple M5 Ultra")
    // What the "true" pair (the measured rates above) serves at two prompt lengths.
    var truthPolicy = ClusterPlacementPolicy()
    let served = try [2 * chunk, 8 * chunk].enumerated().map { index, prompt -> ClusterServedSample in
        truthPolicy.promptTokens = prompt; truthPolicy.outputTokens = 128
        let truth = try ClusterPlacementPlanner.evaluate(devices: pair.setup.devices, cuts: pair.setup.cuts, mode: pair.setup.mode,
            prefillSchedule: pair.setup.schedule, layout: nine, policy: truthPolicy).rested
        return .init(route: .pair, member: nil, promptTokens: prompt, outputTokens: 128, firstTokenSeconds: truth.firstTokenSeconds,
            decodeTokensPerSecond: truth.decodeTokensPerSecond, finishedAt: Double(2_000 + index))
    }
    let placement = ClusterServedCalibration.Placement(devices: [r3, r5], cuts: pair.setup.cuts, mode: pair.setup.mode,
        schedule: pair.setup.schedule, layout: nine)
    let derived = try ClusterServedCalibration.measurements(served, placement: placement, runtimeBinarySHA256: "served",
        measuredUTC: "2026-10-13T00:00:00Z")
    let p3 = derived.first { $0.key.chip == "Apple M3 Ultra" }?.rested, p5 = derived.first { $0.key.chip == "Apple M5 Ultra" }?.rested
    func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 / b - 1) < 0.01 } ?? false }
    checks.require("pair requests turn index ratios into absolute prefill rates (within 1 %)",
        close(p3?.prefillTokensPerSecond, 1_000) && close(p5?.prefillTokensPerSecond, 4_980))
    checks.require("a phase split's decode measures the decoding member with its head, and the other by the index ratio",
        close(p5?.speculativeDecodeTokensPerSecond, 176 * 1.44) && close(p5?.decodeTokensPerSecond, 176)
            && close(p3?.decodeTokensPerSecond, 100))
    // The next plan uses them: measured, absolute, the same placement.
    let estimated = ClusterSpeedEstimator.estimate(devices: [.init(chip: "Apple M3 Ultra", osBuild: "SYNTH"), .init(chip: "Apple M5 Ultra", osBuild: "SYNTH")],
        artifactSHA256: nine.artifactSHA256, promptTokens: 4 * chunk, measurements: derived)
    let replanned = try plan(zip([r3, r5], estimated).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }, nine)
    checks.require("the next plan starts from the served records: measured, absolute, same placement as the true rates give",
        estimated.allSatisfy { $0.source == .measured && $0.absolute } && replanned.result.basis.absolute
            && replanned.setup.cuts == pair.setup.cuts && replanned.setup.mode == pair.setup.mode)
    // A member that served alone measured itself directly.
    let alone = ClusterServedSample(route: .alone, member: "m5ultra", promptTokens: 2_000, outputTokens: 100,
        firstTokenSeconds: 0.5, decodeTokensPerSecond: 250, finishedAt: 3_000)
    let direct = try ClusterServedCalibration.measurements([alone], placement: placement, runtimeBinarySHA256: "served", measuredUTC: "x")
    checks.require("a request served alone measures that Mac's whole-model prefill and decode directly",
        direct.count == 1 && direct[0].key.chip == "Apple M5 Ultra" && close(direct[0].rested.prefillTokensPerSecond, 4_000)
            && close(direct[0].rested.speculativeDecodeTokensPerSecond, 250))

    // Index-only speeds are relative units; a served route is in seconds. With only one route served,
    // the other takes its scale, so the decision stays the planner's ratio (units never decide).
    let relativeSetup = ClusterRequestRouter.Setup(devices: [r3, r5], cuts: pair.setup.cuts, mode: pair.setup.mode,
        schedule: pair.setup.schedule, layout: nine, measuresPair: false, aloneRoute: true)
    for prompt in [chunk, 16 * chunk] {
        let predictedRoute = try ClusterRequestRouter.decide(relativeSetup, promptTokens: prompt, outputTokens: 128)
        var alonePolicy = ClusterPlacementPolicy(); alonePolicy.promptTokens = prompt; alonePolicy.outputTokens = 128
        let units = ClusterPlacementPlanner.evaluateAlone(device: r5, layout: nine, speculativeHead: relativeSetup.mode.usesSpeculativeHead,
            policy: alonePolicy)
        let seconds = ClusterServedSample(route: .alone, member: "m5ultra", promptTokens: prompt, outputTokens: 128,
            firstTokenSeconds: units.firstTokenSeconds / 1_000, decodeTokensPerSecond: units.decodeTokensPerSecond * 1_000, finishedAt: 9)
        let servedRoute = try ClusterRequestRouter.decide(relativeSetup, promptTokens: prompt, outputTokens: 128, served: [seconds])
        checks.require("index units and served seconds are never compared: one served route lends its scale to the other (prompt \(prompt))",
            servedRoute.path == predictedRoute.path && servedRoute.aloneBasis == .served && servedRoute.pairBasis == .predicted
                && abs(servedRoute.pairSeconds / servedRoute.aloneSeconds! - predictedRoute.pairSeconds / predictedRoute.aloneSeconds!) < 0.01)
    }

    // The same from records as a leader keeps them: one setup per (model, mode, cut, ranks);
    // a setup without its rank order, or naming a Mac that is not planned, is skipped and said so.
    let cutText = ClusterServedSpeedRecords.Setup.cut(pair.setup.cuts, layerCount: nine.layerCount)
    let named = ClusterServedSpeedRecords.Setup(modelID: "m", mode: pair.setup.mode.rawValue, cut: cutText, ranks: ["m3ultra", "m5ultra"])
    let unnamed = ClusterServedSpeedRecords.Setup(modelID: "m", mode: pair.setup.mode.rawValue, cut: cutText, ranks: nil)
    let stranger = ClusterServedSpeedRecords.Setup(modelID: "m", mode: pair.setup.mode.rawValue, cut: cutText, ranks: ["m3ultra", "m1"])
    let fromEntries = try ClusterServedCalibration.measurements(entries: served.map { .init(setup: named, sample: $0) }
            + [.init(setup: unnamed, sample: alone), .init(setup: stranger, sample: alone)],
        devices: [r5, r3], layout: nine, link: .unmeasured, measuredUTC: "2026-10-13T00:00:00Z")
    checks.require("served entries give each ranked Mac its measurement whatever order devices are listed in; unranked or unknown setups are skipped",
        fromEntries.measurements.count == 2 && close(fromEntries.measurements.first { $0.key.chip == "Apple M5 Ultra" }?.rested.prefillTokensPerSecond, 4_980)
            && fromEntries.lines.count == 3 && fromEntries.lines.filter { $0.contains("skipped") }.count == 2)

    // The records file: bounded per setup and route, its own encoding, invalid samples dropped.
    let setup = ClusterServedSpeedRecords.Setup(modelID: "m", mode: "phase_split_mtp_v1",
        cut: ClusterServedSpeedRecords.Setup.cut([4], layerCount: 32), ranks: ["a", "b"])
    var records = ClusterServedSpeedRecords()
    for index in 0..<40 {
        records.add(.init(route: .pair, member: nil, promptTokens: 100 + index, outputTokens: 10, firstTokenSeconds: 0.1,
            decodeTokensPerSecond: 50, finishedAt: Double(index)), setup: setup)
    }
    records.add(.init(route: .alone, member: "b", promptTokens: 10, outputTokens: 10, firstTokenSeconds: 0.05,
        decodeTokensPerSecond: 60, finishedAt: 50), setup: setup)
    records.add(.init(route: .alone, member: nil, promptTokens: 10, outputTokens: 10, firstTokenSeconds: 0.05,
        decodeTokensPerSecond: 60, finishedAt: 51), setup: setup)
    records.add(.init(route: .pair, member: nil, promptTokens: 10, outputTokens: 10, firstTokenSeconds: .nan,
        decodeTokensPerSecond: 60, finishedAt: 52), setup: setup)
    let kept = records.samples(for: setup)
    checks.require("served records keep the newest 32 per setup and route, and drop invalid samples",
        kept.filter { $0.route == .pair }.count == 32 && kept.filter { $0.route == .pair }.first?.promptTokens == 108
            && kept.filter { $0.route == .alone }.count == 1)
    checks.require("served records survive their own encoding", try ClusterServedSpeedRecords.decode(records.encoded()) == records)
    checks.require("a cut string reads back to the placement's cuts",
        setup.cut == "0-4|4-32" && ClusterServedSpeedRecords.Setup.cuts("0-4|4-32", layerCount: 32) == [4]
            && ClusterServedSpeedRecords.Setup.cuts("0-4|5-32", layerCount: 32) == nil
            && ClusterServedSpeedRecords.Setup.cuts("0-4|4-31", layerCount: 32) == nil)

    // The planner weighs the member that can hold the whole model against
    // every placement (MiMo on M3 Ultra + M5 Ultra, 2026-10-13: the pair
    // decoded 42 tok/s against 57 on the M5 Ultra alone, every request on the
    // pair because the model was pipeline-only). A 139 GiB model (within the
    // 156 GiB a 256 GB Mac admits at rest, so one member holds it whole) on a
    // fast 256 GB Mac and a slower 256 GB Mac, rates in the measured proportion.
    // The phase split and its alone route are hand-off modes (owner,
    // 2026-10-13: kept, off by default): these checks hold them under the
    // explicit opt-in, and the default plans a sharded deployment only.
    do {
        let fast = try SyntheticMac.idle(256).device("fast", speed: measured(prefill: 1_250, decode: 57), chip: "Apple M5 Ultra")
        let slow = try SyntheticMac.idle(256).device("slow", speed: measured(prefill: 325, decode: 39), chip: "Apple M3 Ultra")
        let every = try syntheticLayout(layers: 48, layerGiB: 2.9, modes: [.pipeline, .pipelineCompactDecode, .phaseSplit])
        var serial = ClusterPlacementPolicy(); serial.schedules = [.serial]; serial.promptTokens = 4_096
        let byDefault = try ClusterPlacementPlanner.plan(devices: [slow, fast], layout: every, policy: serial)
        checks.require("whole-model member, by default: a sharded mode, no request routed alone (chose \(byDefault.chosen?.mode.rawValue ?? "-"))",
            byDefault.chosen?.mode.isSharded == true && byDefault.routedAlone == nil && byDefault.chosen?.aloneRoute == nil)
        serial.handOffModes = true
        let result = try ClusterPlacementPlanner.plan(devices: [slow, fast], layout: every, policy: serial)
        let chosen = result.chosen
        checks.require("whole-model member: a phase split is chosen with the fast Mac decoding, so it can serve requests alone",
            chosen?.mode == .phaseSplit && chosen?.ranks.last?.device == "fast" && chosen?.aloneRoute?.device == "fast")
        checks.require("whole-model member: with a serial prefill the pair is never faster, so the planned request is routed to the fast Mac alone",
            result.routedAlone == "fast" && chosen.map { $0.routedSeconds(.rested) < $0.prediction(.rested).requestSeconds } == true)
        let pipelineOnly = try ClusterPlacementPlanner.evaluate(devices: [fast, slow], cuts: [47], mode: .pipeline,
            prefillSchedule: .serial, layout: every, policy: serial)
        checks.require("whole-model member: the routed phase split ranks ahead of the pipeline that sends every request over the link",
            (chosen?.routedSeconds(.rested) ?? .infinity) < pipelineOnly.routedSeconds(.rested) && pipelineOnly.aloneRoute == nil)
        // With lookahead and a long prompt the pair's prefill wins; the router still serves short prompts alone.
        var long = ClusterPlacementPolicy(); long.promptTokens = 8_000; long.outputTokens = 16; long.handOffModes = true
        var mixed = try syntheticLayout(layers: 48, layerGiB: 2.9, modes: [.pipeline, .phaseSplit])
        mixed = try ClusterModelLayout.decode(mixed.encoded())
        let longResult = try ClusterPlacementPlanner.plan(devices: [slow, fast], layout: mixed, policy: long)
        checks.require("whole-model member, long prompt with lookahead: the pair is predicted faster, so it serves the planned request",
            longResult.chosen?.mode == .phaseSplit && longResult.routedAlone == nil
                && longResult.chosen?.prefillSchedule == .oneChunkLookahead && longResult.chosen?.ranks.last?.device == "fast")
        if let c = longResult.chosen {
            let setup = ClusterRequestRouter.Setup(devices: c.ranks.map { r in [slow, fast].first { $0.label == r.device }! },
                cuts: c.cuts, mode: c.mode, schedule: c.prefillSchedule, layout: mixed, aloneRoute: true)
            let short = try ClusterRequestRouter.decide(setup, promptTokens: 300, outputTokens: 128)
            checks.require("whole-model member, same placement: a short prompt is routed to the fast Mac alone",
                short.path == .alone && short.member == "fast")
        }
        // A model no member can hold whole gets no alone route, and the explanation says nothing of one.
        let huge = try syntheticLayout(layers: 48, layerGiB: 6, modes: [.pipeline, .phaseSplit])
        let capacity = try ClusterPlacementPlanner.plan(devices: [slow, fast], layout: huge, policy: serial)
        checks.require("capacity model: no member holds it whole, so the pair serves it and no request is routed alone",
            capacity.chosen?.mode == .pipeline && capacity.routedAlone == nil && capacity.chosen?.aloneRoute == nil)
        let text = ClusterPlacementExplanation.describe(result, devices: [slow, fast], layout: every).joined(separator: "\n")
        checks.require("whole-model member: the plan says the fast Mac serves this request alone and is never made slower by its pair",
            text.contains("fast alone is predicted faster than the pair") && text.contains("never made slower by its pair"))
    }
}

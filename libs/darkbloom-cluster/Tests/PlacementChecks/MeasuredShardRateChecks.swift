import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Constructed rates exercise the real cost/calibration path; no hardware
/// speed or qualification is inferred from these CPU cases.
func checkMeasuredShardRates(_ baseLayout: ClusterModelLayout, _ checks: PlacementChecks) throws {
    func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 1e-10 }
    for half in [10.0, 90.0, 180.0] {
        let rates = ClusterSpeedRates(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
            tensorShardDecodeTokensPerSecond: half)
        let split = ClusterDecodeSplit(rates: rates)
        checks.require("measured half \(half): both APIs preserve its actual step outside and inside the floor model",
            close(split.shareStepSeconds(fraction: 0.5), 1 / half)
                && close(split.shareStepSeconds(ranks: 2), 1 / half)
                && split.floorSeconds >= 0 && split.weightSeconds >= 0)
        let decoded = try JSONDecoder().decode(ClusterDecodeSplit.self, from: JSONEncoder().encode(split))
        checks.require("measured half \(half): encoded prediction preserves the measured step",
            close(decoded.shareStepSeconds(fraction: 0.5), 1 / half))
    }
    let explicit = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
        tensorShareRates: [.init(sharePerMille: 250, decodeTokensPerSecond: 8),
                           .init(sharePerMille: 500, decodeTokensPerSecond: 10)]))
    checks.require("measured shares: the smallest point is never replaced by a faster fallback",
        close(explicit.shareStepSeconds(fraction: 0.25), 1 / 8.0)
            && close(explicit.shareStepSeconds(ranks: 4), 1 / 8.0)
            && close(explicit.shareStepSeconds(fraction: 0.5), 0.1)
            && close(explicit.shareStepSeconds(ranks: 2), 0.1))
    // The whole model's step (1/60 s) is no endpoint: past the largest share the measured segment goes on, never
    // below that share's own step (this segment falls, so the step stays at the half's).
    checks.require("measured shares: between points keeps the measured interpolation; past them no whole endpoint and never faster",
        close(explicit.shareStepSeconds(fraction: 0.375), 0.1125)
            && close(explicit.shareStepSeconds(fraction: 1), 0.1) && explicit.measuredSteps?.map(\.fraction) == [0.25, 0.5])
    for neighbor in [499, 501] {
        for (half, nearby) in [(10.0, 90.0), (90.0, 10.0)] {
            let split = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000,
                decodeTokensPerSecond: 60, tensorShardDecodeTokensPerSecond: half,
                tensorShareRates: [.init(sharePerMille: neighbor, decodeTokensPerSecond: nearby)]))
            checks.require("measured shares: \(neighbor)-per-mille rate \(nearby) does not replace half rate \(half)",
                close(split.shareStepSeconds(fraction: 0.5), 1 / half)
                    && close(split.shareStepSeconds(ranks: 2), 1 / half)
                    && close(split.shareStepSeconds(fraction: Double(neighbor) / 1000), 1 / nearby))
        }
    }
    let conflicting = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000,
        decodeTokensPerSecond: 60, tensorShardDecodeTokensPerSecond: 90,
        tensorShareRates: [.init(sharePerMille: 500, decodeTokensPerSecond: 10)]))
    checks.require("measured shares: an explicit exact half keeps precedence over the scalar half probe",
        close(conflicting.shareStepSeconds(fraction: 0.5), 0.1)
            && close(conflicting.shareStepSeconds(ranks: 2), 0.1)
            && conflicting.measuredSteps?.filter { $0.fraction == 0.5 }.count == 1)
    let ordinary = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
        tensorShardDecodeTokensPerSecond: 90))
    let unknown = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60))
    let prior = ClusterDecodeSplit(rates: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60),
        hardwareWeightSeconds: 0.01)
    checks.require("measured shares: ordinary half encoding and unmeasured fallbacks stay unchanged",
        ordinary.measuredSteps == nil && unknown.measuredSteps == nil && prior.measuredSteps == nil
            && close(unknown.shareStepSeconds(ranks: 2), 1 / 60.0)
            && close(prior.shareStepSeconds(ranks: 2), 1 / 60.0 - 0.005))
    for invalid in [0.0, -1.0, Double.infinity, Double.nan] {
        checks.refuses("measured shares: nonfinite or nonpositive half cannot become a speed record", because: "malformed") {
            _ = try ClusterSpeedMeasurement(key: .init(artifactSHA256: "synthetic", chip: "synthetic",
                osBuild: "synthetic", runtimeBinarySHA256: "synthetic", probe: "synthetic"),
                promptTokens: 1024, chunkTokens: 512, probedLayers: 1, layerCount: 1,
                rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
                    tensorShardDecodeTokensPerSecond: invalid), sustained: nil,
                measuredUTC: "synthetic", provenance: "CPU refusal case")
        }
    }

    // A severe real-served correction must survive the measurement estimator
    // and a full replan, not just the direct split's arithmetic.
    let layout = try executing(baseLayout, [.tensorParallel])
    let speed = ClusterDeviceSpeed(source: .measured, absolute: true,
        rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
            tensorShardPrefillTokensPerSecond: 1500, tensorShardDecodeTokensPerSecond: 90),
        sustained: nil, explanation: "constructed CPU rates")
    let devices = try [SyntheticMac.idle(256).device("a", speed: speed, chip: "Synthetic A"),
                       SyntheticMac.idle(256).device("b", speed: speed, chip: "Synthetic B")]
    let link = linkCosts(reductionMicroseconds: 1)
    var policy = ClusterPlacementPolicy(); policy.promptTokens = 1024; policy.outputTokens = 128
    policy.modes = [.pipeline, .tensorParallel]; policy.handOffModes = false
    let first = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: policy, link: link)
    let samples = (0..<3).map { ClusterServedSample(route: .pair, member: nil, promptTokens: 1024,
        outputTokens: 128, firstTokenSeconds: first.rested.firstTokenSeconds,
        decodeTokensPerSecond: 10, finishedAt: Double($0 + 1)) }
    let measured = try ClusterServedCalibration.measurements(samples,
        placement: .init(devices: devices, cuts: [], mode: .tensorParallel, schedule: .serial,
            layout: layout, link: link), runtimeBinarySHA256: String(repeating: "f", count: 64), measuredUTC: "synthetic")
    let speeds = ClusterSpeedEstimator.estimate(devices: devices.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
        artifactSHA256: layout.artifactSHA256, measurements: measured)
    let corrected = zip(devices, speeds).map { ClusterPlacementDevice(label: $0.label, profile: $0.profile, speed: $1) }
    let again = try ClusterPlacementPlanner.evaluate(devices: corrected, cuts: [], mode: .tensorParallel,
        prefillSchedule: .serial, layout: layout, policy: policy, link: link)
    let planned = try ClusterPlacementPlanner.plan(devices: corrected, layout: layout, policy: policy, link: link)
    checks.require("served severe slowdown: actual calibration and estimator preserve observed tensor decode",
        measured.count == 2 && close(again.rested.decodeTokensPerSecond, 10)
            && speeds.allSatisfy { $0.rested.decodeTokensPerSecond == 60 })
    checks.require("served severe slowdown: full planner chooses a fitting pipeline without disabling tensor parallel",
        planned.chosen?.mode == .pipeline && planned.tensorParallel?.verdict == .predictedSlower
            && planned.tensorParallel?.tensorParallel?.mode == .tensorParallel)
}

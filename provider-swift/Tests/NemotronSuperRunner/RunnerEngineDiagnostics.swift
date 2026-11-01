import Foundation
import MLXLMCommon
@testable import ProviderCore

/// Read-only engine counters for qualification: cumulative speculation
/// metrics (clients diff two reads) and, when the process runs with
/// `CBV2_STEP_PROFILE=1`, the step profiler's phase timings.
enum RunnerEngineDiagnostics {
    static func json(bridge: EngineV2Bridge) async -> RunnerJSON {
        let engine = await bridge.ownedEngine as? EngineV2
        return ["mtp": mtp(engine?.mtpMetricsSnapshot()), "profile": profile()]
    }

    /// Clears the profiler's samples; speculation counters stay cumulative.
    static func resetProfile() -> RunnerJSON {
        CBv2StepProfiler.reset()
        return ["profile_enabled": .bool(CBv2StepProfiler.enabled)]
    }

    private static func mtp(_ metrics: CBv2MTPMetrics?) -> RunnerJSON {
        guard let metrics else { return .null }
        func counts(_ values: [Int: Int]) -> RunnerJSON {
            .object(Dictionary(uniqueKeysWithValues: values.map { (String($0.key), .count($0.value)) }))
        }
        return [
            "rounds": .count(metrics.rounds), "seed_steps": .count(metrics.seedSteps),
            "drafted_tokens": .count(metrics.draftedTokens),
            "accepted_tokens": .count(metrics.acceptedTokens),
            "emitted_tokens": .count(metrics.emittedTokens),
            "rectangular_verification_rounds": .count(metrics.rectangularVerificationRounds),
            "per_position_accepted": .array(metrics.perPositionAccepted.map { .count($0) }),
            "depth_selections": counts(metrics.depthSelections),
            "skipped_rows": .object(metrics.skippedRows.mapValues { .count($0) }),
            "controller_fallbacks": .object(metrics.controllerFallbacks.mapValues { .count($0) }),
        ]
    }

    private static func profile() -> RunnerJSON {
        guard CBv2StepProfiler.enabled else { return .null }
        var phases: [String: RunnerJSON] = [:]
        for (phase, samples) in CBv2StepProfiler.snapshot() where !samples.isEmpty {
            let sorted = samples.sorted()
            phases[phase] = [
                "count": .count(samples.count),
                "total_ms": .double(samples.reduce(0, +) * 1000),
                "p50_ms": .double(sorted[sorted.count / 2] * 1000),
                "p90_ms": .double(sorted[min(sorted.count - 1, sorted.count * 9 / 10)] * 1000),
            ]
        }
        return .object(phases)
    }
}

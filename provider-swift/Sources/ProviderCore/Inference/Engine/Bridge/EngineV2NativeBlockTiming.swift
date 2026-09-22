import Foundation
import MLXLMCommon

/// Block generation must include the first canvas's work. A burst divided by
/// first-delta→finish can look arbitrarily fast despite long generation latency.
enum EngineV2NativeBlockTiming {
    static func generationRate(completionTokens: Int, timing: CBv2RequestTiming) -> Double? {
        guard completionTokens > 0, timing.promptComputedNanos > 0,
            timing.finishedNanos > timing.promptComputedNanos else { return nil }
        let seconds = Double(timing.finishedNanos - timing.promptComputedNanos) / 1_000_000_000
        let rate = Double(completionTokens) / seconds
        return rate.isFinite && rate > 0 ? rate : nil
    }

    static func prefillSeconds(_ timing: CBv2RequestTiming) -> Double? {
        guard timing.prefillFirstLaunchNanos > 0,
            timing.promptComputedNanos > timing.prefillFirstLaunchNanos else { return nil }
        return Double(timing.promptComputedNanos - timing.prefillFirstLaunchNanos) / 1_000_000_000
    }
}

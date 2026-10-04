import Foundation

/// Output events can contain several committed MTP tokens. No token inside
/// one event has its own observed timestamp, so the first event is excluded
/// from the numerator of the observed first-to-last-event interval.
struct ModelPrefixBenchmarkOutputTiming {
    static let definition = "tokens_after_first_nonempty_output_event / last_minus_first_event_seconds; nil_for_one_event"
    private(set) var first: ContinuousClock.Instant?
    private(set) var last: ContinuousClock.Instant?
    private(set) var firstOutputTokenCount = 0
    private(set) var outputEventCount = 0
    private(set) var completedOutputTokens = 0

    mutating func record(tokenCount: Int, at time: ContinuousClock.Instant) {
        guard tokenCount > 0 else { return }
        if first == nil {
            first = time
            firstOutputTokenCount = tokenCount
        }
        last = time
        outputEventCount += 1
        completedOutputTokens += tokenCount
    }

    var generationTPS: Double? {
        guard outputEventCount > 1, let first, let last else { return nil }
        let duration = last - first
        let interval = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        guard interval > 0 else { return nil }
        return Double(completedOutputTokens - firstOutputTokenCount) / interval
    }
}

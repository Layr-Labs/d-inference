import Foundation

/// Keep the receipt boundary separate from the later serialized-request
/// quiescence boundary. Neither timestamp denotes fsync durability.
struct ModelPrefixBenchmarkQuiescenceTiming: Sendable {
    let quiescenceCompletionSeconds: Double
    let receiptToQuiescenceMilliseconds: Double
    let quiescenceCompletionTPS: Double
    let checkpointWritesDrained: Bool

    init(started: ContinuousClock.Instant, receiptCompleted: ContinuousClock.Instant,
         quiescenceCompleted: ContinuousClock.Instant, outputTokens: Int) {
        quiescenceCompletionSeconds = Self.seconds(quiescenceCompleted - started)
        receiptToQuiescenceMilliseconds = Self.seconds(quiescenceCompleted - receiptCompleted) * 1_000
        quiescenceCompletionTPS = Double(outputTokens) / quiescenceCompletionSeconds
        checkpointWritesDrained = true
    }

    static func measure(
        started: ContinuousClock.Instant, receiptCompleted: ContinuousClock.Instant,
        outputTokens: Int, requireIdle: () async throws -> Void,
        drainCheckpointWrites: () async throws -> Void
    ) async throws -> Self {
        try await requireIdle()
        try await drainCheckpointWrites()
        return Self(started: started, receiptCompleted: receiptCompleted,
            quiescenceCompleted: .now, outputTokens: outputTokens)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

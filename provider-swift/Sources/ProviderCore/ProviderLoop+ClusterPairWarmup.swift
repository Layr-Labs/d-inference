import Foundation

// Warmup canary on every pair formation (S18), from the owner's ThunderMLX
// loop (`m3_warmup.py`, an 8-token throwaway generation on each boot): the
// first generation after a load absorbs a one-off cost and, on that pair,
// was where first-generation wedges happened. Here it runs on the leader
// after the pair slot is registered and BEFORE admission opens, so the
// coordinator never routes a request into a pair that has not generated once.
// A canary that fails or times out retires the slot: the committed start
// ends and the coordinator forms the pair again, instead of serving from a
// pair that cannot generate.

public struct ClusterPairWarmupResult: Sendable, Equatable, CustomStringConvertible {
    public let succeeded: Bool
    public let tokens: Int
    public let seconds: Double
    public let detail: String?

    public var description: String {
        succeeded ? "ok (\(tokens) tokens in \(String(format: "%.2f", seconds)) s)"
            : "failed after \(String(format: "%.1f", seconds)) s: \(detail ?? "no detail")"
    }
}

extension ProviderLoop {
    static let clusterWarmupEnvironmentKey = "DARKBLOOM_CLUSTER_WARMUP"
    static let clusterWarmupMaxTokens = 8
    static let clusterWarmupTimeoutSeconds: Double = 300

    /// Off only with an explicit `0` / `false` / `no` / `off`.
    static func clusterWarmupEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[clusterWarmupEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    /// nil turns the canary off for this loop; otherwise its deadline.
    func setClusterPairWarmupForTesting(timeoutSeconds: Double?) { clusterPairWarmupTimeoutSeconds = timeoutSeconds }

    /// One greedy request of at most eight tokens through the pair's bridge.
    static func runClusterPairWarmup(bridge: EngineV2Bridge, modelID: String,
                                     timeoutSeconds: Double = clusterWarmupTimeoutSeconds) async -> ClusterPairWarmupResult {
        let started = ContinuousClock.now
        func elapsed() -> Double {
            let duration = ContinuousClock.now - started
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let requestID = "cluster-warmup-\(UUID().uuidString.prefix(12).lowercased())"
        // Every sampling knob explicit and greedy: an omitted knob takes the model's
        // generation_config default (e.g. Qwen top_p 0.95 / top_k 20), which the
        // pair engine refuses as non-greedy (`unsupportedRequest`), so the canary
        // would retire every pair it was meant to warm.
        let request = ChatCompletionRequest(model: modelID, messages: [ChatMessage(role: "user", content: "Reply with OK.")],
                                            temperature: 0, top_p: 1, top_k: 0, max_tokens: clusterWarmupMaxTokens,
                                            repetition_penalty: 1, presence_penalty: 0, frequency_penalty: 0, stream: true)
        // No prefix-cache receipt: the pair's workers serve only cold, receipt-free
        // requests ("stop strings stay in the provider" refusal otherwise), as the
        // pair's own scheduler submits them.
        let stream = await bridge.submit(request: request, requestId: requestID, cacheEnabled: false)
        let outcome = ClusterWarmupOutcome()
        let consumer = Task {
            var chunks = 0
            for await event in stream {
                switch event {
                case .chunk:
                    chunks += 1
                case .info(_, let completionTokens, _, _):
                    outcome.finish(.init(succeeded: completionTokens > 0, tokens: completionTokens, seconds: 0,
                                         detail: completionTokens > 0 ? nil : "no tokens generated"))
                    return
                case .error(let message):
                    outcome.finish(.init(succeeded: false, tokens: chunks, seconds: 0, detail: String(message.prefix(200))))
                    return
                case .terminal:
                    outcome.finish(.init(succeeded: false, tokens: chunks, seconds: 0, detail: "engine terminal"))
                    return
                default:
                    break
                }
            }
            outcome.finish(.init(succeeded: chunks > 0, tokens: chunks, seconds: 0,
                                 detail: chunks > 0 ? nil : "stream ended without tokens"))
        }
        while outcome.value == nil, elapsed() < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let result = outcome.value else {
            await bridge.cancel(requestId: requestID)
            consumer.cancel()
            return .init(succeeded: false, tokens: 0, seconds: elapsed(), detail: "timed out after \(Int(timeoutSeconds)) s")
        }
        return .init(succeeded: result.succeeded, tokens: result.tokens, seconds: elapsed(), detail: result.detail)
    }
}

final class ClusterWarmupOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ClusterPairWarmupResult?
    var value: ClusterPairWarmupResult? { lock.withLock { result } }
    func finish(_ value: ClusterPairWarmupResult) { lock.withLock { if result == nil { result = value } } }
}

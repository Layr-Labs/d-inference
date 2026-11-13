import CryptoKit
import Foundation

extension DaemonState {
    /// One answer this daemon is writing now. Local observation only: no
    /// prompt, no output, no request id (a short hash of it at most).
    public struct RunningRequest: Codable, Sendable, Equatable {
        public var model: String
        /// The first 8 hex digits of the SHA-256 of the provider's request id:
        /// tells two answers apart, names neither.
        public var ref: String
        /// Seconds since the engine took the request, at `writtenAt`.
        public var elapsedSeconds: Double
        /// Output tokens so far, thinking included.
        public var outputTokens: Int
        /// Output tokens per second since the previous sample (the average
        /// since the first token on a request's first sample); nil before
        /// its first token.
        public var tokensPerSecond: Double?

        public init(model: String, ref: String, elapsedSeconds: Double, outputTokens: Int, tokensPerSecond: Double?) {
            self.model = model
            self.ref = ref
            self.elapsedSeconds = elapsedSeconds
            self.outputTokens = outputTokens
            self.tokensPerSecond = tokensPerSecond
        }
    }
}

/// Turns the bridges' per-request counters (`EngineV2Bridge.runningRequestSamples`,
/// kept for every request already) into `DaemonState.runningRequests`: each
/// answer's elapsed time, tokens so far and current rate. One sample per
/// capacity tick, no per-token work.
struct RunningRequestProgressTracker {
    struct Sample: Sendable, Equatable {
        let id: String
        let model: String
        /// Since the engine took the request.
        let sinceAdmission: Duration
        /// Since its first token; nil before it.
        let sinceFirstToken: Duration?
        let outputTokens: Int
    }

    /// At most this many answers are listed, longest first.
    static let maximumListed = 32

    private var previous: [String: (tokens: Int, at: TimeInterval)] = [:]

    /// The running answers at `now` (monotonic seconds), longest first.
    /// Requests that ended since the last call are forgotten.
    mutating func update(_ samples: [Sample], now: TimeInterval) -> [DaemonState.RunningRequest] {
        var next: [String: (tokens: Int, at: TimeInterval)] = [:]
        let running = samples.map { sample -> DaemonState.RunningRequest in
            next[sample.id] = (sample.outputTokens, now)
            return DaemonState.RunningRequest(
                model: sample.model,
                ref: Self.ref(sample.id),
                elapsedSeconds: Self.seconds(sample.sinceAdmission),
                outputTokens: sample.outputTokens,
                tokensPerSecond: rate(sample, now: now))
        }
        previous = next
        return Array(running.sorted { ($0.elapsedSeconds, $0.ref) > ($1.elapsedSeconds, $1.ref) }
            .prefix(Self.maximumListed))
    }

    private func rate(_ sample: Sample, now: TimeInterval) -> Double? {
        guard let sinceFirstToken = sample.sinceFirstToken else { return nil }
        if let last = previous[sample.id], now - last.at >= 0.5, sample.outputTokens >= last.tokens {
            return Double(sample.outputTokens - last.tokens) / (now - last.at)
        }
        let decoding = Self.seconds(sinceFirstToken)
        return decoding >= 0.5 ? Double(sample.outputTokens) / decoding : nil
    }

    static func ref(_ requestID: String) -> String {
        SHA256.hash(data: Data(requestID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}

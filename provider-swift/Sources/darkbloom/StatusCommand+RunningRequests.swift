import Foundation
import ProviderCore

extension Status {
    static let creditsLine = "Credits post when an answer finishes."

    /// The answers this Mac (or its pair) is writing now, under the serving
    /// block. The served and token counters move only when an answer
    /// finishes, so a Mac writing two long answers otherwise reads as hung.
    /// Elapsed time counts on from the snapshot to `now`.
    static func runningRequestLines(state: DaemonState, now: Double) -> [String] {
        guard let running = state.runningRequests, !running.isEmpty else { return [] }
        let age = state.ageSeconds(now: now)
        var lines = ["Answers in progress: \(running.count)"]
        for request in running {
            let rate = request.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "reading the prompt"
            let elapsed = DurationFormatting.compact(
                request.elapsedSeconds + age, secondsInMinuteRange: true, elideZeroMinutesInHourRange: false)
            lines.append("  \(request.model): \(elapsed), \(request.outputTokens) tokens so far, \(rate) (#\(request.ref))")
        }
        lines.append("  \(creditsLine)")
        return lines
    }

    /// `status --json`: the running provider's answers in progress. `daemon`
    /// is `running`, `stale` (the state file is older than the daemon's
    /// wedge bar), or `not_running`; a stopped daemon lists none.
    static func statusJSON(state: DaemonState?, alive: Bool, now: Double, heartbeatIntervalSecs: UInt64,
                           clusterPart: Bool) throws -> Data {
        var document: [String: Any] = ["schema": 1, "version": ProviderCore.version]
        var answers: [[String: Any]] = []
        if let state, alive {
            let age = state.ageSeconds(now: now)
            let wedged = age > KVBackendPosture.wedgedAfterSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs)
            document["daemon"] = wedged ? "stale" : "running"
            document["pid"] = Int(state.pid)
            document["snapshot_age_seconds"] = tenths(age)
            document["cluster_part"] = clusterPart
            answers = (state.runningRequests ?? []).map { request in
                var answer: [String: Any] = [
                    "model": request.model, "ref": request.ref,
                    "elapsed_seconds": tenths(request.elapsedSeconds + age),
                    "output_tokens": request.outputTokens,
                ]
                if let rate = request.tokensPerSecond { answer["tokens_per_second"] = tenths(rate) }
                return answer
            }
        } else {
            document["daemon"] = "not_running"
        }
        document["answers_in_progress"] = answers
        document["note"] = creditsLine
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

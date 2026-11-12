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
        var document = AnswersInProgressDocument(daemon: "not_running")
        if let state, alive {
            let age = state.ageSeconds(now: now)
            let wedged = age > KVBackendPosture.wedgedAfterSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs)
            document.daemon = wedged ? "stale" : "running"
            document.pid = state.pid
            document.snapshotAgeSeconds = tenths(age)
            document.clusterPart = clusterPart
            document.answersInProgress = (state.runningRequests ?? []).map { request in
                .init(model: request.model, ref: request.ref, elapsedSeconds: tenths(request.elapsedSeconds + age),
                      outputTokens: request.outputTokens, tokensPerSecond: request.tokensPerSecond.map(tenths))
            }
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// One decimal, encoded as written (`JSONEncoder` prints a double's
    /// shortest form, so 10.7 stays 10.7).
    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// `status --json`, schema 1. Absent fields are omitted.
private struct AnswersInProgressDocument: Encodable {
    struct Answer: Encodable {
        let model: String
        let ref: String
        let elapsedSeconds: Double
        let outputTokens: Int
        let tokensPerSecond: Double?
    }

    let schema = 1
    let version = ProviderCore.version
    var daemon: String
    var pid: Int32?
    var snapshotAgeSeconds: Double?
    var clusterPart: Bool?
    var answersInProgress: [Answer] = []
    let note = Status.creditsLine
}

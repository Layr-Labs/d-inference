import Foundation
import DarkbloomClusterProcess

/// Owner-side time budgets of one registered model: the model-dependent waits
/// the installed path applies to a worker. The collective progress limit and
/// the owners' signal margins do not depend on the model and are not here.
struct DistributedInstalledTimeBudgets: Sendable, Equatable {
    /// Longest a rank may take from launch to `ready`: load its stage (both
    /// stages for rank 1 under phase split) and join its peer.
    let startupAllowanceNanoseconds: UInt64
    /// First-token allowance: a fixed part plus a part per prompt token.
    let firstTokenBaseMilliseconds: Int64
    let firstTokenMillisecondsPerPromptToken: Int64
    /// Longest a rank may take to answer a reservation.
    let admissionWaitNanoseconds: UInt64
    /// Longest a rank may take to answer `shutdown` before its command stream
    /// is closed. Closing the stream sends no signal; the rank keeps releasing.
    let shutdownAcknowledgementNanoseconds: UInt64
    /// Added to the collective progress limit for a clean stop: a rank releases
    /// its model and its owner exchanges the release.
    let stopMarginNanoseconds: UInt64
    /// Longest a stop of the session waits for a request that is still running
    /// to end at its next committed token before the request is cancelled.
    /// Ending at a token leaves both ranks able to shut down at once;
    /// cancelling ends them, and one still inside a collective then needs the
    /// progress limit. Sized to reach the first token of the longest prompt.
    let cleanStopWaitNanoseconds: UInt64

    var pairTiming: ClusterWorkerPairTiming {
        .init(admissionWaitNanoseconds: admissionWaitNanoseconds,
              shutdownAcknowledgementNanoseconds: shutdownAcknowledgementNanoseconds,
              cleanStopWaitNanoseconds: cleanStopWaitNanoseconds)
    }
}

/// The margins that turn a setup into time budgets (owner, 2026-10-14:
/// budgets are derived from the plan and the Macs, not typed per model).
/// Policy, typed on purpose, beside what it scales; no value names a model or
/// a chip.
struct DistributedInstalledBudgetPolicy: Sendable {
    /// A rank's load is the verified loader hashing the whole artifact, then
    /// materializing its stage. These floors are below the slowest rates any
    /// Mac recorded (hash 1.8 GB/s, materialize 2.45 GB/s on an M3 Ultra for
    /// the 27B; an M5 Ultra hashed MiMo's 163 GB at about 12.7 GB/s).
    var hashBytesPerSecond = 1.5e9
    var materializeBytesPerSecond = 2.0e9
    /// A rank may take this many times its floor-rate load before it is given up on.
    var startupMargin = 4.0
    var startupFloorSeconds = 90.0
    /// The fixed part of the first-token allowance.
    var firstTokenBaseMilliseconds: Int64 = 10_000
    /// A reservation is bookkeeping in each rank and loads nothing.
    var admissionWaitSeconds = 5.0
    /// Releasing the weights and exchanging the release: a fixed part plus a
    /// part per stored byte, within bounds (every recorded release took under
    /// 0.3 s).
    var shutdownBaseSeconds = 2.0, shutdownBytesPerSecond = 20e9, shutdownCeilingSeconds = 15.0
    var stopMarginBaseSeconds = 15.0, stopMarginBytesPerSecond = 10e9, stopMarginCeilingSeconds = 45.0
    /// The setup's request deadline is the planner's prediction for the
    /// longest request times `ClusterPlacementRequestLimits.Policy.margin`
    /// plus its base; the clean-stop wait is twice that prediction, within
    /// bounds. The ceiling is the pair's own longest wait
    /// (`ClusterWorkerPairTiming.longestWaitNanoseconds`, one minute): the pair
    /// refuses a longer one before it starts, so a request still running a
    /// minute into a stop is cancelled.
    var requestDeadlineMargin = 3.0, requestDeadlineBaseSeconds = 30.0
    var cleanStopFloorSeconds = 10.0
    var cleanStopCeilingSeconds = Double(ClusterWorkerPairTiming.longestWaitNanoseconds) / 1e9
    /// Below the protocol's hour (`ClusterWorkerLimits.deadlineNanoseconds`).
    var startupCeilingSeconds = 3_540.0
    init() {}
}

extension DistributedInstalledTimeBudgets {
    /// The budgets of one installed setup, derived instead of read from a
    /// per-model row:
    ///
    /// - first token: `firstTokenBaseMilliseconds` plus a share per prompt
    ///   token that reaches the setup's request deadline at the longest prompt
    ///   the worker admits. That deadline is the planner's prediction for the
    ///   longest request on the chosen placement and the detected Macs times
    ///   three, plus 30 s (`ClusterPlacementRequestLimits`), so the allowance is
    ///   at least three times the predicted prefill; a plan from relative
    ///   speeds only has the codec's ceiling, and the collective progress
    ///   limit still ends a stalled rank;
    /// - startup: hashing the whole artifact (twice on a rank that loads every
    ///   layer under a phase split) and materializing the largest stage at
    ///   floor rates, times the margin, within bounds;
    /// - shutdown and stop: by the stored bytes, within bounds;
    /// - clean-stop wait: twice the predicted longest request, within bounds
    ///   (at most the pair's one-minute longest wait).
    ///
    /// `artifactBytes` is the verified manifest's total; nil (before the
    /// manifest is read) takes each bound's ceiling.
    static func derived(requestTimeoutSeconds: Int, maximumPromptTokens: Int, artifactBytes: Int64?,
                        largestStageShare: Double, lastRankLoadsEverything: Bool,
                        policy: DistributedInstalledBudgetPolicy = .init()) -> (budgets: Self, basis: [String]) {
        func nanoseconds(_ seconds: Double) -> UInt64 { UInt64((seconds * 1e9).rounded(.up)) }
        func text(_ value: Double) -> String { String(format: "%.1f", value) }
        let deadlineMilliseconds = Int64(max(1, requestTimeoutSeconds)) * 1000
        let prompts = Int64(max(1, maximumPromptTokens))
        let share = (deadlineMilliseconds - policy.firstTokenBaseMilliseconds + prompts - 1) / prompts
        let perToken = max(1, share)
        let bytes = artifactBytes.map { Double(max(0, $0)) }
        let stage = min(1, max(0, lastRankLoadsEverything ? 1 : largestStageShare))
        let startup: Double, shutdown: Double, stopMargin: Double
        if let bytes {
            let load = Double(lastRankLoadsEverything ? 2 : 1) * bytes / policy.hashBytesPerSecond + stage * bytes / policy.materializeBytesPerSecond
            startup = min(policy.startupCeilingSeconds, max(policy.startupFloorSeconds, (load * policy.startupMargin).rounded(.up)))
            // To the nearest second: the base is already a margin over every release recorded.
            shutdown = min(policy.shutdownCeilingSeconds, (policy.shutdownBaseSeconds + bytes / policy.shutdownBytesPerSecond).rounded())
            stopMargin = min(policy.stopMarginCeilingSeconds, (policy.stopMarginBaseSeconds + bytes / policy.stopMarginBytesPerSecond).rounded())
        } else {
            startup = policy.startupCeilingSeconds; shutdown = policy.shutdownCeilingSeconds; stopMargin = policy.stopMarginCeilingSeconds
        }
        let predictedLongest = max(0, (Double(requestTimeoutSeconds) - policy.requestDeadlineBaseSeconds) / policy.requestDeadlineMargin)
        let pairLongest = Double(ClusterWorkerPairTiming.longestWaitNanoseconds) / 1e9
        let cleanStop = min(pairLongest, policy.cleanStopCeilingSeconds, max(policy.cleanStopFloorSeconds, (2 * predictedLongest).rounded(.up)))
        let budgets = Self(startupAllowanceNanoseconds: nanoseconds(startup),
            firstTokenBaseMilliseconds: policy.firstTokenBaseMilliseconds, firstTokenMillisecondsPerPromptToken: perToken,
            admissionWaitNanoseconds: nanoseconds(policy.admissionWaitSeconds),
            shutdownAcknowledgementNanoseconds: nanoseconds(shutdown), stopMarginNanoseconds: nanoseconds(stopMargin),
            cleanStopWaitNanoseconds: nanoseconds(cleanStop))
        let size = bytes.map { text($0 / 1e9) + " GB" } ?? "an artifact not yet measured"
        return (budgets, [
            "Startup \(Int(startup)) s: \(size) hashed\(lastRankLoadsEverything ? " twice" : "") at \(text(policy.hashBytesPerSecond / 1e9)) GB/s "
                + "and \(Int((stage * 100).rounded()))% of it materialized at \(text(policy.materializeBytesPerSecond / 1e9)) GB/s, "
                + "times \(text(policy.startupMargin)), at least \(Int(policy.startupFloorSeconds)) s.",
            "First token \(policy.firstTokenBaseMilliseconds / 1000) s plus \(perToken) ms per prompt token: the setup's request deadline "
                + "(\(requestTimeoutSeconds) s, from the planned placement's predicted speed) at its longest prompt (\(maximumPromptTokens) tokens).",
            "Clean stop \(Int(cleanStop)) s, shutdown \(Int(shutdown)) s, stop margin \(Int(stopMargin)) s: twice the predicted longest request, "
                + "and the release of \(size).",
        ])
    }
}

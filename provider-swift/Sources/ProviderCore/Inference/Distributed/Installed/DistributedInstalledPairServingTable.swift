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

/// A model the installed path will not serve on a pair, and why.
struct DistributedInstalledServingRefusal: Error, Equatable, CustomStringConvertible {
    enum Reason: Equatable { case pairServingWithheld, noRow }
    let runtimeModelID: String
    let publicModelID: String
    let reason: Reason

    var description: String {
        switch reason {
        case .pairServingWithheld:
            return "This cluster's model, \(publicModelID) (registered as \(runtimeModelID)), is not open to serving on a two-Mac pair. "
                + "Serving a model on a pair needs its own explicit grant for that model, and none has been given for this one. "
                + "That is a policy decision, not a fault in this setup: no cluster setting, generation mode or time budget changes it."
        case .noRow:
            return "This darkbloom's pair-serving table has no row for the registered model \(runtimeModelID) (\(publicModelID)). "
                + "That is an omission in this build, not a fault in the setup: a model is served on a pair only with time budgets measured for it."
        }
    }
}

/// The registered models the installed path knows, one row each: whether a
/// pair may serve the model and, if so, with which time budgets.
///
/// A row is keyed by the runtime's own model identity, which comes from the
/// worker's capability record and which a setup cannot rename. The provider's
/// model eligibility gate is keyed by the public model identity and is
/// separate; this table relaxes nothing in it.
enum DistributedInstalledPairServingTable {
    enum PairServing: Sendable, Equatable {
        case open(DistributedInstalledTimeBudgets)
        /// Not granted. The budgets are groundwork derived for the day it is;
        /// nothing in the serving path can read them.
        case withheld(groundwork: DistributedInstalledTimeBudgets)
    }
    struct Row: Sendable, Equatable {
        let runtimeModelID: String
        let pairServing: PairServing
    }

    /// Registered Qwen3.5 9B.
    ///
    /// - Startup, 90 s. The pair was measured ready in 5.8 s on the faster Mac
    ///   and 7.3 s on the slower one as a pipeline, and in 8.6 s and
    ///   11.3 to 12.3 s under phase split, where rank 1 loads both stages. The
    ///   allowance is sized for the slowest of these, at seven times it.
    /// - First token, 10 s plus 1 ms per prompt token. 1 ms per token is the
    ///   slower Mac prefilling alone (about 990 tokens a second), a floor for
    ///   any pair that includes it. The first token is selected by the pair
    ///   before a phase-split hand-off, so the mode does not enter this budget;
    ///   the hand-off (26 to 71 ms measured, 20 s by the ranks' own agreement)
    ///   and the first relay batches fall after it.
    /// - Admission, 5 s. A reservation is bookkeeping in each rank and loads
    ///   nothing.
    /// - Shutdown acknowledgement, 2 s, and stop margin, 15 s: releasing
    ///   5 GB of weights and exchanging the release.
    /// - Clean-stop wait, 10 s. A token follows the last within 25 ms as a
    ///   pipeline and within a relayed batch of about 0.25 s under phase
    ///   split; the first token of the longest prompt (8,192 tokens) was
    ///   measured 4.0 to 4.6 s after the request arrived. 10 s is twice that.
    static let qwen35 = Row(runtimeModelID: "registered_qwen35_9b", pairServing: .open(.init(
        startupAllowanceNanoseconds: 90_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 1,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 2_000_000_000, stopMarginNanoseconds: 15_000_000_000,
        cleanStopWaitNanoseconds: 10_000_000_000)))

    /// Registered Qwen3.8 27B. Derived from single-Mac measurements; no pair
    /// has run this model.
    ///
    /// - Startup, 120 s. Rank 1's stage loaded in 7.4 to 13.7 s (cut 16). Under
    ///   phase split rank 1 loads the whole model; for the 9B that took 1.7
    ///   times its stage load, which puts this model at about 23 s. 120 s is
    ///   five times that and leaves 180 s of the 300 s session to serve.
    /// - First token, 10 s plus 4 ms per prompt token. The slower Mac prefills
    ///   this model alone at about 300 tokens a second, 3.3 ms per token,
    ///   rounded up. At 8,192 tokens the budget is 42.8 s against about 15 s
    ///   expected of the pair without lookahead and 8 s with it.
    /// - Admission, 5 s: the same bookkeeping as for the 9B.
    /// - Shutdown acknowledgement, 6 s, and stop margin, 20 s: three times the
    ///   weights to release (15.1 GB against 5.0 GB).
    /// - Clean-stop wait, 20 s: the first token of the longest prompt is
    ///   expected about 15 s after the request arrives, without lookahead.
    static let qwen38 = Row(runtimeModelID: "registered_qwen38_27b", pairServing: .withheld(groundwork: .init(
        startupAllowanceNanoseconds: 120_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 4,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 6_000_000_000, stopMarginNanoseconds: 20_000_000_000,
        cleanStopWaitNanoseconds: 20_000_000_000)))

    static let rows = [qwen35, qwen38]

    /// The budgets of a model a pair may serve; a refusal for every other model.
    static func servingBudgets(runtimeModelID: String, publicModelID: String) throws -> DistributedInstalledTimeBudgets {
        guard let row = rows.first(where: { $0.runtimeModelID == runtimeModelID }) else {
            throw DistributedInstalledServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .noRow)
        }
        guard case .open(let budgets) = row.pairServing else {
            throw DistributedInstalledServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .pairServingWithheld)
        }
        return budgets
    }
}

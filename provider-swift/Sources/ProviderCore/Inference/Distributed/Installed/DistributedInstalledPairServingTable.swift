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

/// A registered model this build has no time budgets for.
struct DistributedInstalledServingRefusal: Error, Equatable, CustomStringConvertible {
    let runtimeModelID: String
    let publicModelID: String

    var description: String {
        "This darkbloom's pair-serving table has no row for the registered model \(runtimeModelID) (\(publicModelID)). "
            + "That is an omission in this build, not a fault in the setup: a model is served on a pair only with time budgets measured for it."
    }
}

/// The registered models the installed path knows, one row each: the time
/// budgets a pair serves the model with. Whether a pair may serve the model,
/// and on which chip classes, is its grant (`ClusterPairServingGrants`), not
/// this table.
///
/// A row is keyed by the runtime's own model identity, which comes from the
/// worker's capability record and which a setup cannot rename.
enum DistributedInstalledPairServingTable {
    struct Row: Sendable, Equatable {
        let runtimeModelID: String
        let budgets: DistributedInstalledTimeBudgets
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
    static let qwen35 = Row(runtimeModelID: "registered_qwen35_9b", budgets: .init(
        startupAllowanceNanoseconds: 90_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 1,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 2_000_000_000, stopMarginNanoseconds: 15_000_000_000,
        cleanStopWaitNanoseconds: 10_000_000_000))

    /// Registered Qwen3.8 27B, granted on mixed chips (owner decision D4,
    /// derived from its qualification records, `ClusterPairServingGrants`). Derived from single-Mac
    /// measurements, then checked against the pair's own: across the cable
    /// the pair has run this model since 2026-10-09 (pipeline, phase split,
    /// MTP, prefix reuse, prompts to 30,720 tokens) inside these budgets.
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
    static let qwen38 = Row(runtimeModelID: "registered_qwen38_27b", budgets: .init(
        startupAllowanceNanoseconds: 120_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 4,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 6_000_000_000, stopMarginNanoseconds: 20_000_000_000,
        cleanStopWaitNanoseconds: 20_000_000_000))

    /// Registered Qwen3.5 35B A3B (20.9 GB), granted in the order its
    /// cross-cable checks ran (its qualification records, `ClusterPairServingGrants`).
    /// Every figure is the pair's own, across the cable, 2026-10-09 to 10-11.
    ///
    /// - Startup, 150 s. Both ranks were ready in 18.0 to 25.8 s as a pipeline
    ///   and in 28.4 to 29.0 s under phase split, where rank 1 loads the whole
    ///   model. 150 s is five times the slowest.
    /// - First token, 10 s plus 1 ms per prompt token. The slower Mac prefills
    ///   this model alone at 1,460 to 1,860 tokens a second, 0.54 to 0.69 ms
    ///   per token, rounded up. The pair's first token was measured 1.0 to
    ///   8.5 s after a 4,096-token request (the longest, the first request of
    ///   a session) against 14.1 s here, and 8.7 s after 16,384 tokens.
    /// - Admission, 5 s: bookkeeping, as for every model.
    /// - Shutdown acknowledgement, 8 s, and stop margin, 25 s: four times the
    ///   9B's weights to release; shutdown was measured in 0.13 to 0.22 s.
    /// - Clean-stop wait, 20 s: twice the first token of the longest prompt
    ///   measured (16,384 tokens, 8.7 s).
    static let qwen35A3B = Row(runtimeModelID: "registered_qwen35_35b_a3b", budgets: .init(
        startupAllowanceNanoseconds: 150_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 1,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 8_000_000_000, stopMarginNanoseconds: 25_000_000_000,
        cleanStopWaitNanoseconds: 20_000_000_000))

    /// Registered Qwen3.6 35B A3B, text only (21.3 GB): the same shape and
    /// the same figures as the Qwen3.5 35B A3B within the spread of the runs.
    /// Ready in 18.1 to 25.1 s as a pipeline, 28.5 to 29.1 s under phase split
    /// and 30.4 to 30.6 s with its MTP head loaded; the slower Mac alone
    /// prefills at 1,730 to 1,860 tokens a second; first token 1.0 to 3.0 s
    /// after 4,096 tokens and 8.3 s after 16,384; shutdown 0.12 to 0.22 s.
    static let qwen36A3B = Row(runtimeModelID: "registered_qwen36_35b_a3b", budgets: qwen35A3B.budgets)

    /// Registered Ternary Bonsai 2 27B (8.6 GB), granted in the order its
    /// cross-cable checks ran (its qualification records, `ClusterPairServingGrants`).
    ///
    /// - Startup, 90 s. Both ranks were ready in 7.4 to 9.4 s as a pipeline
    ///   and in 11.5 to 11.8 s under phase split; 90 s is seven times that.
    /// - First token, 10 s plus 4 ms per prompt token. The slower Mac prefills
    ///   this model alone at 280 to 300 tokens a second, 3.3 to 3.6 ms per
    ///   token, rounded up. At 8,192 tokens the budget is 42.8 s against
    ///   21.4 s measured on the pair without lookahead and 11.9 to 14.5 s with
    ///   it; at 16,384 tokens 75.5 s against 45.5 s.
    /// - Admission, 5 s.
    /// - Shutdown acknowledgement, 3 s, and stop margin, 15 s: under twice the
    ///   9B's weights; shutdown was measured in 0.12 to 0.27 s.
    /// - Clean-stop wait, 30 s: the first token of the longest prompt this
    ///   build admits (8,192 tokens) came 21.4 s after the request without
    ///   lookahead.
    static let bonsai2 = Row(runtimeModelID: "registered_ternary_bonsai_2_27b", budgets: .init(
        startupAllowanceNanoseconds: 90_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 4,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 3_000_000_000, stopMarginNanoseconds: 15_000_000_000,
        cleanStopWaitNanoseconds: 30_000_000_000))

    /// Registered Nemotron 3.5 Lightning (19.1 GB), granted in the order its
    /// cross-cable checks ran (its qualification records, `ClusterPairServingGrants`).
    ///
    /// - Startup, 120 s. Both ranks were ready in 14.9 to 16.8 s as a pipeline
    ///   and in 19.7 s under phase split; 120 s is six times that.
    /// - First token, 10 s plus 1 ms per prompt token. The slower Mac prefills
    ///   this model alone at about 1,750 tokens a second, 0.57 ms per token,
    ///   rounded up. The pair's first token was measured 0.2 to 4.7 s after a
    ///   34-token request, 2.0 to 5.5 s after 4,096 tokens and 8.3 s after
    ///   16,384.
    /// - Admission, 5 s.
    /// - Shutdown acknowledgement, 8 s, and stop margin, 25 s: four times the
    ///   9B's weights; shutdown was measured in 0.15 to 0.17 s.
    /// - Clean-stop wait, 20 s: twice the first token of the longest prompt
    ///   measured (16,384 tokens, 8.3 s).
    static let nemotron35 = Row(runtimeModelID: "registered_nemotron35_lightning", budgets: .init(
        startupAllowanceNanoseconds: 120_000_000_000,
        firstTokenBaseMilliseconds: 10_000, firstTokenMillisecondsPerPromptToken: 1,
        admissionWaitNanoseconds: 5_000_000_000,
        shutdownAcknowledgementNanoseconds: 8_000_000_000, stopMarginNanoseconds: 25_000_000_000,
        cleanStopWaitNanoseconds: 20_000_000_000))

    /// One row for every model with a pair-serving grant, in the grants' order,
    /// and none for a model whose grant is withheld.
    static let rows = [qwen35, qwen38, qwen35A3B, qwen36A3B, bonsai2, nemotron35]

    /// The budgets of a model this build has a row for; a refusal for every other model.
    static func servingBudgets(runtimeModelID: String, publicModelID: String) throws -> DistributedInstalledTimeBudgets {
        guard let row = rows.first(where: { $0.runtimeModelID == runtimeModelID }) else {
            throw DistributedInstalledServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        }
        return row.budgets
    }
}

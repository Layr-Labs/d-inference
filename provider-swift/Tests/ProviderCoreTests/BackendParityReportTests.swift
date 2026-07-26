// Copyright © 2026 Eigen Labs.
//
// Gate G2's verdict logic, exercised WITHOUT a model.
//
// The live half needs 15 GB of weights and both KV backends; the decision half
// — which criterion passed, which was skipped, and what the process exit
// status is — is pure and must be provable in CI. Every honesty rule the gate
// claims is pinned here, in particular the one the sweep benchmark got wrong
// this wave: a run that evaluated NOTHING must not exit 0.

import Foundation
import Testing

@testable import ProviderBenchmark

@Suite("gate G2: parity report verdicts and exit status")
struct BackendParityReportTests {

    // MARK: - Fixtures

    private func criterion(
        _ id: BackendParityReport.CriterionID,
        _ verdict: BackendParityReport.Verdict
    ) -> BackendParityReport.Criterion {
        BackendParityReport.Criterion(
            id: id, title: "\(id.rawValue)", verdict: verdict, detail: "fixture")
    }

    private func row(
        _ prompt: String, _ tokens: [Int], finish: String = "stop"
    ) -> BackendParityObservation.Row {
        BackendParityObservation.Row(prompt: prompt, tokens: tokens, finishReason: finish)
    }

    /// A fully-populated arm that passes every criterion, so each test can
    /// perturb exactly one thing.
    private func healthyArm(
        selection: String,
        resolved: String,
        prefillTokensSaved: Int = 256
    ) -> BackendParityObservation {
        BackendParityObservation(
            selection: selection,
            resolvedBackend: resolved,
            rows: [row("a", [1, 2, 3]), row("b", [4, 5])],
            mtp: BackendParityObservation.MTP(
                rows: [row("a", [1, 2, 3]), row("b", [4, 5])],
                driverConstructed: true,
                rounds: 6,
                draftedTokens: 30,
                acceptedTokens: 21),
            packedPrefill: BackendParityObservation.Capability(
                active: true, detail: "probe active"),
            visionSpans: BackendParityObservation.Capability(
                active: true, detail: "span served"),
            prefixReuse: BackendParityObservation.PrefixReuse(
                capabilitySupported: true,
                capabilityStrategy: "direct",
                replayBoundTokens: 25600,
                promptTokens: 28672,
                donatedEntries: 4,
                firstOutcome: "miss",
                secondOutcome: "hit",
                secondMatchedTokens: prefillTokensSaved,
                secondPrefillTokensSaved: prefillTokensSaved,
                cacheHits: 1,
                cacheMisses: 1,
                cacheTokensSaved: prefillTokensSaved))
    }

    private var baseline: BackendParityObservation {
        healthyArm(selection: "contiguous", resolved: "contiguous")
    }

    private var candidate: BackendParityObservation {
        healthyArm(selection: "paged", resolved: "paged")
    }

    // MARK: - Exit status

    @Test("an all-skipped run does NOT exit 0 as if it passed")
    func allSkippedIsNotSuccess() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .unavailable),
            criterion(.mtpTokenExactness, .unavailable),
            criterion(.packedPrefill, .unavailable),
            criterion(.visionSpans, .unavailable),
            criterion(.prefixReuse, .unavailable),
        ])
        #expect(outcome == .nothingEvaluated(skipped: 5))
        #expect(outcome.exitStatus == 2)
        #expect(outcome.exitStatus != 0)
        #expect(outcome.summary.contains("INCONCLUSIVE"))
        #expect(outcome.summary.contains("not a pass"))
    }

    @Test("no criteria at all is inconclusive, never a pass")
    func emptyCriteriaIsNotSuccess() {
        let outcome = BackendParityOutcome(criteria: [])
        #expect(outcome == .nothingEvaluated(skipped: 0))
        #expect(outcome.exitStatus == 2)
    }

    @Test("any failing criterion exits 1 and names the failures")
    func failureExitsNonZero() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.mtpTokenExactness, .fail),
            criterion(.prefixReuse, .fail),
        ])
        #expect(outcome == .failed(
            criteria: ["mtp_token_exactness", "prefix_reuse"], shortfalls: []))
        #expect(outcome.exitStatus == 1)
        #expect(outcome.summary.contains("mtp_token_exactness"))
        #expect(outcome.summary.contains("prefix_reuse"))
    }

    @Test("a failure outranks skips: the run is a FAIL, not inconclusive")
    func failureOutranksSkips() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .fail),
            criterion(.packedPrefill, .unavailable),
            criterion(.visionSpans, .unavailable),
        ])
        #expect(outcome.exitStatus == 1)
    }

    @Test("all evaluated criteria passing exits 0")
    func allPassExitsZero() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.prefixReuse, .pass),
        ])
        #expect(outcome == .passed(evaluated: 2, skipped: 0, shortfalls: []))
        #expect(outcome.exitStatus == 0)
        #expect(!outcome.summary.contains("UNAVAILABLE"))
    }

    @Test("a partial pass exits 0 but says how much it could not measure")
    func partialPassAdvertisesSkips() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.packedPrefill, .unavailable),
            criterion(.visionSpans, .unavailable),
        ])
        #expect(outcome == .passed(evaluated: 1, skipped: 2, shortfalls: []))
        #expect(outcome.exitStatus == 0)
        #expect(outcome.summary.contains("2 UNAVAILABLE"))
    }

    @Test("the three outcomes have three distinct exit statuses")
    func statusesAreDistinguishable() {
        let statuses = Set([
            BackendParityOutcome.passed(evaluated: 1, skipped: 0, shortfalls: []).exitStatus,
            BackendParityOutcome.failed(criteria: ["x"], shortfalls: []).exitStatus,
            BackendParityOutcome.nothingEvaluated(skipped: 3).exitStatus,
        ])
        #expect(statuses.count == 3)
    }

    @Test("an EXPECTED_SHORTFALL does not fail the run on its own")
    func expectedShortfallDoesNotExitNonZero() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.prefixReuse, .expectedShortfall),
        ])
        #expect(outcome == .passed(
            evaluated: 2, skipped: 0, shortfalls: ["prefix_reuse"]))
        #expect(outcome.exitStatus == 0)
    }

    @Test("an EXPECTED_SHORTFALL is named in the SUMMARY, not buried in a detail")
    func expectedShortfallRidesTheSummaryLine() {
        // A reader who only sees the tail of a CI log must not come away
        // believing the backends matched.
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.prefixReuse, .expectedShortfall),
        ])
        #expect(outcome.summary.contains("EXPECTED SHORTFALL"))
        #expect(outcome.summary.contains("prefix_reuse"))
        #expect(outcome.summary.contains("NOT parity"))
    }

    @Test("a shortfall still rides the summary when something else failed")
    func shortfallSurvivesAFailure() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .fail),
            criterion(.prefixReuse, .expectedShortfall),
        ])
        #expect(outcome == .failed(
            criteria: ["token_exactness"], shortfalls: ["prefix_reuse"]))
        #expect(outcome.exitStatus == 1)
        #expect(outcome.summary.contains("G2 FAIL: token_exactness"))
        #expect(outcome.summary.contains("EXPECTED SHORTFALL: prefix_reuse"))
    }

    @Test("a run of only shortfalls is evaluated, not inconclusive")
    func shortfallCountsAsEvaluated() {
        // A shortfall IS a measurement. Collapsing it into "nothing ran"
        // would throw away the one number that was actually taken.
        let outcome = BackendParityOutcome(criteria: [
            criterion(.prefixReuse, .expectedShortfall),
            criterion(.packedPrefill, .unavailable),
        ])
        #expect(outcome == .passed(
            evaluated: 1, skipped: 1, shortfalls: ["prefix_reuse"]))
        #expect(outcome.exitStatus == 0)
    }

    // MARK: - Comparison preconditions

    @Test("two arms that resolved to the SAME backend are not a comparison")
    func sameResolvedBackendBlocksEveryCriterion() {
        // A kill-switched paged selection degrades to contiguous. Comparing
        // contiguous with contiguous passes everything and proves nothing.
        let degraded = BackendParityObservation(
            selection: "paged",
            resolvedBackend: "contiguous",
            fallbackReason: "kill_switch",
            rows: baseline.rows,
            mtp: baseline.mtp,
            packedPrefill: baseline.packedPrefill,
            visionSpans: baseline.visionSpans,
            prefixReuse: baseline.prefixReuse)

        let criteria = BackendParityCriteria.evaluate(
            baseline: baseline, candidate: degraded)
        #expect(criteria.count == 5)
        #expect(criteria.allSatisfy { $0.verdict == .unavailable })
        #expect(criteria.allSatisfy { $0.detail.contains("both arms resolved to contiguous") })
        #expect(criteria.allSatisfy { $0.detail.contains("kill_switch") })
        #expect(BackendParityOutcome(criteria: criteria).exitStatus == 2)
    }

    @Test("an arm that built no engine blocks every criterion with its reason")
    func constructionFailureBlocksEveryCriterion() {
        let refused = BackendParityObservation(
            selection: "paged",
            constructionFailure: "pagedUnavailable(\"kernel preflight failed\")")
        let criteria = BackendParityCriteria.evaluate(
            baseline: baseline, candidate: refused)
        #expect(criteria.allSatisfy { $0.verdict == .unavailable })
        #expect(criteria.allSatisfy { $0.detail.contains("kernel preflight failed") })
    }

    @Test("arm labels report the RESOLVED backend, not the requested one")
    func labelUsesResolvedBackend() {
        let degraded = BackendParityObservation(
            selection: "paged", resolvedBackend: "contiguous", fallbackReason: "kill_switch")
        #expect(degraded.label == "contiguous (fallback: kill_switch)")
        #expect(!degraded.label.hasPrefix("paged"))

        let refused = BackendParityObservation(
            selection: "paged", constructionFailure: "refused")
        #expect(refused.label == "paged (unresolved)")

        let clean = BackendParityObservation(selection: "paged", resolvedBackend: "paged")
        #expect(clean.label == "paged")
    }

    // MARK: - Token exactness

    @Test("identical token ids and finish reasons pass")
    func tokenExactnessPasses() {
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: candidate)
        #expect(result.verdict == .pass)
        #expect(result.measurements["contiguous"] == "2 rows, 5 tokens, finish=stop")
        #expect(result.measurements["paged"] == "2 rows, 5 tokens, finish=stop")
    }

    // MARK: - Same-backend numerics control

    private func drifted() -> BackendParityObservation {
        BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4, 99])])
    }

    @Test("a control that also flips leads the detail: NOT a backend difference")
    func controlThatFlipsLeadsTheDetail() {
        // The reader must meet "the incumbent also flips here" BEFORE the
        // divergence it explains, so it cannot be missed.
        let control = BackendParityReport.NumericsControl(
            perturbation: "paged pool dtype float16 -> float32",
            tokenExact: false,
            detail: "paged fp32 diverged from paged fp16 on the SAME backend",
            firstFlip: "1 of 3 rows diverged — prompt 'a' token 1")
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted(), control: control)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.hasPrefix("CONTROL SAYS THIS IS NOT A BACKEND DIFFERENCE"))
        #expect(result.detail.contains("no cross-backend token comparison on this model is "
            + "meaningful"))
        #expect(result.measurements["control"] == "NOT token-exact")
    }

    @Test("a control that HOLDS says the difference is not benign numerics")
    func controlThatHoldsIsStated() {
        let control = BackendParityReport.NumericsControl(
            perturbation: "paged pool dtype float16 -> float32",
            tokenExact: true,
            detail: "identical across 3 prompts")
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted(), control: control)
        #expect(result.detail.hasPrefix("CONTROL HELD"))
        #expect(result.detail.contains("NOT explained by benign numerics"))
        #expect(result.measurements["control"] == "TOKEN-EXACT")
        // Still UNAVAILABLE: re-arming FAIL is gated on the promotion
        // criterion, not on a single clean control.
        #expect(result.verdict == .unavailable)
    }

    @Test("a control that could not run says so rather than implying either answer")
    func controlNotRunIsStated() {
        let control = BackendParityReport.NumericsControl(
            perturbation: "paged pool dtype float16 -> float32",
            tokenExact: nil,
            detail: "requested fp32 pages but the pool resolved float16")
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted(), control: control)
        #expect(result.detail.hasPrefix("CONTROL NOT RUN"))
        #expect(result.detail.contains("pool resolved float16"))
        #expect(result.measurements["control"] == "NOT RUN")
    }

    @Test("an ignored dtype knob can never masquerade as a clean control")
    func ignoredKnobIsNotAControl() {
        // tokenExact must be nil, never true, when the perturbation did not
        // actually happen — otherwise a silently-ignored knob produces a
        // second identical arm that looks like agreement.
        let ignored = BackendParityReport.NumericsControl(
            perturbation: "paged pool dtype float16 -> float32",
            tokenExact: nil,
            detail: "requested fp32 pages but the pool resolved nil — the perturbation "
                + "never happened, so this arm is NOT a control")
        #expect(ignored.tokenExact == nil)
        #expect(ignored.headline.hasPrefix("CONTROL NOT RUN"))
        #expect(!ignored.headline.contains("CONTROL HELD"))
    }

    @Test("the control survives a JSON round trip on the report")
    func controlRoundTrips() throws {
        let control = BackendParityReport.NumericsControl(
            perturbation: "paged pool dtype float16 -> float32",
            tokenExact: false, detail: "diverged", firstFlip: "prompt 'a' token 1")
        let report = BackendParityReport(
            modelID: "m", modelPath: "/tmp/m",
            arms: [baseline.arm, candidate.arm],
            numericsControl: control,
            criteria: BackendParityCriteria.evaluate(
                baseline: baseline, candidate: candidate, control: control))
        let decoded = try JSONDecoder().decode(
            BackendParityReport.self, from: Data(try report.jsonString().utf8))
        #expect(decoded.numericsControl == control)
        #expect(report.renderTable().contains("control (paged pool dtype float16 -> "
            + "float32): NOT token-exact"))
    }

    @Test("token exactness NEVER fails: a divergence is UNAVAILABLE with the first flip")
    func tokenExactnessIsPassOnly() {
        // The incumbent fails free-running token exactness too — contiguous
        // against contiguous diverges on gemma-4 under the operator-REACHABLE
        // DARKBLOOM_CBV2_ATTN_QUERY_BLOCK knob (977a5893e). Reachable is the
        // load-bearing word, not "supported": AttentionV1 accepts any value
        // >= 0 at runtime with no version gate, so release policy declining
        // to bless a non-default value does not close the path. A bar the
        // incumbent cannot clear must not be used to accuse the challenger.
        let healthy = candidate
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4, 99])],
            mtp: healthy.mtp, packedPrefill: healthy.packedPrefill,
            visionSpans: healthy.visionSpans, prefixReuse: healthy.prefixReuse)

        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .unavailable)
        #expect(result.verdict != .fail)
        #expect(result.detail.contains("token 1"))
        #expect(result.detail.contains("5 vs 99"))
        #expect(result.detail.contains("NOT scored as a regression"))
        #expect(result.measurements["firstFlip"] != nil)
    }

    @Test("token exactness reports only the FIRST flip, never a divergence rate")
    func tokenExactnessReportsFirstFlipOnly() {
        // Past the first flip the two arms decode different contexts, so
        // later positions compare unrelated conversations. Only the first
        // divergence per row is a real observation.
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 9, 9]), row("b", [4, 5])])
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .unavailable)
        // One row flipped, at index 1 — not "2 of 3 tokens wrong".
        #expect(result.detail.contains("1 of 2 rows diverged"))
        #expect(result.detail.contains("token 1"))
    }

    @Test("an unresolvable argmax tie is named with its margin and floor")
    func tokenExactnessReportsArgmaxSlack() {
        // fp16 KV cannot resolve a gap below ~1/2048 of the logit scale, so
        // the report must say whether the tie was decidable at all.
        let tight = BackendParityObservation.Row(
            prompt: "a", tokens: [1, 2, 3], finishReason: "stop",
            margins: [4.0, 1e-6, 4.0])
        let base = BackendParityObservation(
            selection: "contiguous", resolvedBackend: "contiguous", rows: [tight])
        let cand = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 7, 3])])
        let result = BackendParityCriteria.tokenExactness(baseline: base, candidate: cand)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("NOT resolvable"))
        #expect(result.measurements["argmaxMargin"] != nil)
        #expect(result.measurements["resolvableFloor"] != nil)
    }

    @Test("a comfortably resolvable tie is reported as resolvable, still not a FAIL")
    func tokenExactnessReportsResolvableSlack() {
        let wide = BackendParityObservation.Row(
            prompt: "a", tokens: [1, 2, 3], finishReason: "stop",
            margins: [4.0, 3.5, 4.0])
        let base = BackendParityObservation(
            selection: "contiguous", resolvedBackend: "contiguous", rows: [wide])
        let cand = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 7, 3])])
        let result = BackendParityCriteria.tokenExactness(baseline: base, candidate: cand)
        #expect(result.detail.contains("was resolvable"))
        #expect(result.verdict == .unavailable)
    }

    @Test("a differing finish reason is also UNAVAILABLE, not a FAIL")
    func tokenExactnessFinishReasonIsUnavailable() {
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4, 5], finish: "length")])
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("stop vs length"))
    }

    @Test("a truncated stream is UNAVAILABLE rather than matching on its shared prefix")
    func tokenExactnessPrefixIsUnavailable() {
        let truncated = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4])])
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: truncated)
        #expect(result.verdict == .unavailable)
        #expect(result.verdict != .pass)
        #expect(result.detail.contains("lengths 2 vs 1"))
    }

    @Test("no rows means UNAVAILABLE, never a pass")
    func tokenExactnessWithoutRowsIsUnavailable() {
        let empty = BackendParityObservation(selection: "paged", resolvedBackend: "paged")
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: empty)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("no greedy rows"))
    }

    @Test("firstDivergence points at the index where the streams part")
    func firstDivergenceIsExact() {
        #expect(BackendParityCriteria.firstDivergence([1, 2, 3], [1, 2, 3]) == nil)
        #expect(BackendParityCriteria.firstDivergence([1, 2, 3], [1, 9, 3]) == 1)
        #expect(BackendParityCriteria.firstDivergence([1, 2], [1, 2, 3]) == 2)
        #expect(BackendParityCriteria.firstDivergence([], []) == nil)
        #expect(BackendParityCriteria.firstDivergence([], [7]) == 0)
    }

    // MARK: - MTP

    @Test("MTP that produced NO drafts fails even though its tokens match")
    func inertMTPFailsDespiteMatchingTokens() {
        // The gemma-4 paged silent no-op: a constructed driver that never
        // drafts emits the target's own tokens, so the output comparison is
        // satisfied by a feature that did nothing.
        let inert = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: candidate.rows,
            mtp: BackendParityObservation.MTP(
                rows: baseline.mtp!.rows,
                driverConstructed: true,
                inactiveReason: nil,
                rounds: 0,
                draftedTokens: 0,
                acceptedTokens: 0,
                skippedRows: ["batch_gate": 12]))

        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: inert)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("produced no drafts"))
        #expect(result.detail.contains("paged"))
        #expect(result.measurements["paged"]?.contains("rounds=0") == true)
        #expect(result.measurements["paged"]?.contains("batch_gate=12") == true)
    }

    @Test("a non-nil MTP snapshot with zero counters is not enough to pass")
    func constructedDriverAloneIsNotProof() {
        let constructedOnly = BackendParityObservation.MTP(
            rows: [], driverConstructed: true, rounds: 0, draftedTokens: 0)
        #expect(!constructedOnly.producedDrafts)

        let working = BackendParityObservation.MTP(
            rows: [], driverConstructed: true, rounds: 3, draftedTokens: 12)
        #expect(working.producedDrafts)

        // Rounds without drafted tokens is still a no-op.
        let roundsOnly = BackendParityObservation.MTP(
            rows: [], driverConstructed: true, rounds: 3, draftedTokens: 0)
        #expect(!roundsOnly.producedDrafts)
    }

    @Test("a driver refused on BOTH backends for the same reason is UNAVAILABLE")
    func pairLevelMTPRefusalIsUnavailable() {
        // `CBv2MTPRoundDriver.build` returning nil identically on both arms is
        // a model/drafter-pair or process-config fact, not a paged regression.
        // Booking it as FAIL would blame the backend for the pairing.
        let reason = "model/drafter pair cannot prove matching MTP target identity"
        func arm(_ selection: String) -> BackendParityObservation {
            BackendParityObservation(
                selection: selection, resolvedBackend: selection,
                rows: [row("a", [1, 2, 3])],
                mtp: BackendParityObservation.MTP(
                    rows: [row("a", [1, 2, 3])],
                    driverConstructed: false,
                    inactiveReason: reason))
        }
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: arm("contiguous"), candidate: arm("paged"))
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("no MTP driver was constructed on either backend"))
        #expect(result.detail.contains(reason))
    }

    @Test("a driver refused on ONE backend only is a FAIL — that IS a parity gap")
    func oneSidedMTPRefusalFails() {
        let refusedOnPaged = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: candidate.rows,
            mtp: BackendParityObservation.MTP(
                rows: baseline.mtp?.rows ?? [],
                driverConstructed: false,
                inactiveReason: "paged backend rejected the drafter"))
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: refusedOnPaged)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("produced no drafts on paged"))
    }

    @Test("a missing assistant is UNAVAILABLE, not a failure")
    func missingDrafterIsUnavailable() {
        let noAssistant = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: candidate.rows,
            mtp: BackendParityObservation.MTP(
                unavailableReason: "no MTP assistant supplied (--assistant-model)"))
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: noAssistant)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("--assistant-model"))
    }

    @Test("MTP not run at all on an arm is UNAVAILABLE")
    func absentMTPIsUnavailable() {
        let none = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged", rows: candidate.rows, mtp: nil)
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: none)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("no drafter supplied"))
    }

    /// An arm whose plain decode and MTP decode are stated independently, so
    /// a test can perturb the two comparisons the criterion makes — the arm
    /// against ITSELF, and the arm against the other arm — one at a time.
    private func mtpArm(
        selection: String,
        resolved: String,
        rows: [BackendParityObservation.Row],
        mtpRows: [BackendParityObservation.Row]
    ) -> BackendParityObservation {
        BackendParityObservation(
            selection: selection, resolvedBackend: resolved,
            rows: rows,
            mtp: BackendParityObservation.MTP(
                rows: mtpRows,
                driverConstructed: true, rounds: 6, draftedTokens: 30, acceptedTokens: 21))
    }

    @Test("MTP that reproduces its OWN decode on both arms passes despite base drift")
    func mtpLosslessOnBothArmsPassesEvenWhenBaseDecodeDrifts() {
        // The gemma-4 shape: plain greedy decode already differs between the
        // backends, and the MTP rows carry that difference through. Scored
        // cross-arm this looked like an MTP divergence and had to be waived.
        // Scored per-arm it is a clean PASS with a PROOF attached: MTP == its
        // own target on both sides, so the cross-backend MTP delta is exactly
        // the base-decode delta and cannot be an MTP effect.
        let driftedRows = [row("a", [1, 2, 9]), row("b", [4, 5])]
        let drifted = mtpArm(
            selection: "paged", resolved: "paged",
            rows: driftedRows, mtpRows: driftedRows)
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .pass)
        #expect(result.detail.contains("OWN plain greedy decode"))
        #expect(result.detail.contains("EXACTLY the base-decode divergence"))
        // The cross-backend difference is still reported, never hidden by the
        // pass — a reader must not conclude the two streams matched.
        #expect(result.measurements["crossBackendMTP"] != nil)
        #expect(result.measurements["contiguous MTP vs own decode"] == "token-exact")
        #expect(result.measurements["paged MTP vs own decode"] == "token-exact")
    }

    @Test("MTP lossy against its OWN decode on the candidate is a FAIL")
    func mtpLossyOnCandidateOnlyFails() {
        // Base decode agrees, so nothing here is inherited: the candidate's
        // MTP rows differ from the candidate's own plain rows. Verified greedy
        // speculation is lossless by construction, so that IS an MTP defect.
        let mtpOnly = mtpArm(
            selection: "paged", resolved: "paged",
            rows: baseline.rows, mtpRows: [row("a", [1, 2, 9]), row("b", [4, 5])])
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: mtpOnly)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("OWN plain greedy"))
        #expect(result.detail.contains("inherits no base-decode drift"))
        #expect(result.measurements["paged MTP vs own decode"] != "token-exact")
    }

    @Test("an MTP defect on paged FAILS even when the base decode also drifts")
    func mtpLossyOnCandidateFailsEvenWhenBaseDecodeDrifts() {
        // THE regression test for the unreachable gate. Under the previous
        // cross-arm scoring this exact shape returned UNAVAILABLE — the base
        // decode diverges, so every MTP divergence was written off as
        // inherited. On gemma-4 the base decode diverges on 2 of 3 parity
        // prompts, so that branch swallowed every possible MTP defect on the
        // one model the migration is about.
        //
        // Here paged's MTP differs from PAGED'S OWN plain decode on prompt b,
        // which no amount of cross-backend drift can explain. It must FAIL.
        let broken = mtpArm(
            selection: "paged", resolved: "paged",
            rows: [row("a", [1, 2, 9]), row("b", [4, 5])],
            mtpRows: [row("a", [1, 2, 9]), row("b", [4, 77])])

        // Both conditions the OLD cross-arm scoring keyed on are present in
        // this fixture, which is exactly why it used to be waived: the base
        // decode diverges between the arms, AND the two arms' MTP streams
        // diverge. Asserting them here keeps this a real discriminator — if
        // someone reverts to cross-arm scoring, the verdict below flips to
        // UNAVAILABLE and this test fails.
        #expect(BackendParityCriteria.rowMismatch(
            baseline: baseline.rows, candidate: broken.rows) != nil)
        #expect(BackendParityCriteria.rowMismatch(
            baseline: baseline.mtp?.rows ?? [], candidate: broken.mtp?.rows ?? []) != nil)
        // Neither of those can explain paged's MTP disagreeing with PAGED.
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: broken)
        #expect(result.verdict == .fail)
        #expect(result.verdict != .unavailable)
        #expect(result.detail.contains("token 1: 5 vs 77"))
    }

    @Test("MTP lossy on the BASELINE is UNAVAILABLE and blames the incumbent")
    func mtpLossyOnBaselineIsUnavailable() {
        // A bar the incumbent fails cannot judge the challenger — the same
        // rule tokenExactness applies to free-running decode.
        let lossyBaseline = mtpArm(
            selection: "contiguous", resolved: "contiguous",
            rows: [row("a", [1, 2, 3]), row("b", [4, 5])],
            mtpRows: [row("a", [1, 2, 3]), row("b", [4, 88])])
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: lossyBaseline, candidate: candidate)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("the INCUMBENT failed this bar"))
        // A future reader must not mistake this for "paged was untestable".
        #expect(result.detail.contains("NOT a statement that paged is"))
        #expect(result.detail.contains("token-exact against its own plain decode"))
        #expect(result.measurements["paged MTP vs own decode"] == "token-exact")
    }

    @Test("MTP lossy on BOTH arms is UNAVAILABLE, not a paged FAIL")
    func mtpLossyOnBothArmsIsUnavailable() {
        // Losing losslessness on both backends identically is a model/drafter
        // property, not a paged regression.
        let lossyBaseline = mtpArm(
            selection: "contiguous", resolved: "contiguous",
            rows: [row("a", [1, 2, 3])], mtpRows: [row("a", [1, 2, 88])])
        let lossyCandidate = mtpArm(
            selection: "paged", resolved: "paged",
            rows: [row("a", [1, 2, 3])], mtpRows: [row("a", [1, 2, 88])])
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: lossyBaseline, candidate: lossyCandidate)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("not token-exact either"))
    }

    @Test("MTP rows without plain rows to compare them against is UNAVAILABLE")
    func mtpWithoutOwnTargetIsUnavailable() {
        // No own-target decode means the losslessness question has no left
        // operand. Falling back to the cross-arm comparison here is exactly
        // the shortcut this criterion was rewritten to remove.
        let noPlainRows = mtpArm(
            selection: "paged", resolved: "paged",
            rows: [], mtpRows: [row("a", [1, 2, 3]), row("b", [4, 5])])
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: noPlainRows)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("nothing to measure MTP losslessness against"))
    }

    @Test("MTP passes only when both arms drafted AND each reproduced its own decode")
    func mtpPassRequiresDraftsAndEquality() {
        let pass = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: candidate)
        #expect(pass.verdict == .pass)
        #expect(pass.detail.contains("both backends drafted"))
        // Nothing drifted anywhere, so no cross-backend caveat is attached.
        #expect(pass.measurements["crossBackendMTP"] == nil)

        let drifted = mtpArm(
            selection: "paged", resolved: "paged",
            rows: candidate.rows, mtpRows: [row("a", [1, 2, 3]), row("b", [4, 77])])
        let fail = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(fail.verdict == .fail)
        #expect(fail.detail.contains("MTP output diverged"))
    }

    @Test("an MTP defect on paged makes the WHOLE G2 run exit non-zero")
    func mtpDefectFailsTheRunNotJustTheCriterion() {
        // The half of this blocker that a per-criterion assertion cannot
        // catch. `BackendParityOutcome` only reaches `.failed` when some
        // criterion is `.fail`; UNAVAILABLE merely increments `skipped`, so
        // with any other criterion passing the run still exits 0. While MTP
        // divergence could only ever be UNAVAILABLE, a run with observably
        // different MTP token streams reported a G2 PASS.
        //
        // Same gemma-4 shape as above — base decode drifts AND paged's MTP is
        // lossy against its own target — driven through the full evaluate()
        // path to prove the exit status actually moves.
        let broken = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 9]), row("b", [4, 5])],
            mtp: BackendParityObservation.MTP(
                rows: [row("a", [1, 2, 9]), row("b", [4, 77])],
                driverConstructed: true, rounds: 6, draftedTokens: 30, acceptedTokens: 21),
            packedPrefill: candidate.packedPrefill,
            visionSpans: candidate.visionSpans,
            prefixReuse: candidate.prefixReuse)

        let criteria = BackendParityCriteria.evaluate(baseline: baseline, candidate: broken)
        let mtp = criteria.first { $0.id == BackendParityReport.CriterionID.mtpTokenExactness.rawValue }
        #expect(mtp?.verdict == .fail)

        let outcome = BackendParityOutcome(criteria: criteria)
        #expect(outcome.exitStatus == 1)
        #expect(outcome.summary.contains("G2 FAIL"))
        #expect(outcome.summary.contains("mtp_token_exactness"))
        // Other criteria still passed; the failure is what decides the run.
        if case .passed = outcome { Issue.record("a real MTP defect must not exit 0") }
    }

    @Test("drafts produced but no rows captured is UNAVAILABLE, not a pass")
    func draftsWithoutRowsIsUnavailable() {
        let noRows = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: candidate.rows,
            mtp: BackendParityObservation.MTP(
                rows: [], driverConstructed: true, rounds: 4, draftedTokens: 20))
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: noRows)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("no MTP rows were captured"))
    }

    // MARK: - Capability criteria

    @Test("an undetermined capability is UNAVAILABLE on either arm")
    func undeterminedCapabilityIsUnavailable() {
        let undetermined = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            packedPrefill: .undetermined("no public accessor reports the packed path"),
            visionSpans: BackendParityObservation.Capability(
                active: true, detail: "served"))
        let packed = BackendParityCriteria.packedPrefill(
            baseline: baseline, candidate: undetermined)
        #expect(packed.verdict == .unavailable)
        #expect(packed.detail.contains("no public accessor"))
        #expect(packed.measurements["paged"]?.hasPrefix("UNDETERMINED") == true)

        // The other capability on the same arm still resolves independently.
        let vision = BackendParityCriteria.visionSpans(
            baseline: baseline, candidate: undetermined)
        #expect(vision.verdict == .pass)
    }

    @Test("a capability inactive on one arm fails and says which")
    func inactiveCapabilityFails() {
        let inactive = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            visionSpans: BackendParityObservation.Capability(
                active: false, detail: "backend refused the span request"))
        let result = BackendParityCriteria.visionSpans(
            baseline: baseline, candidate: inactive)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("paged"))
        #expect(result.detail.contains("backend refused"))
        #expect(!result.detail.contains("contiguous:"))
    }

    @Test("a capability active on both arms passes")
    func activeCapabilityPasses() {
        let result = BackendParityCriteria.visionSpans(
            baseline: baseline, candidate: candidate)
        #expect(result.verdict == .pass)
        #expect(result.detail.contains("active on contiguous and paged"))
    }

    // MARK: - Prefix reuse

    @Test("zero reuse on BOTH backends is vacuous, not a pass")
    func vacuousPrefixReuseIsUnavailable() {
        // paged >= contiguous is arithmetically true at 0 >= 0 and means
        // nothing: the workload never exercised the cache.
        let noneBase = healthyArm(
            selection: "contiguous", resolved: "contiguous", prefillTokensSaved: 0)
        let noneCandidate = healthyArm(
            selection: "paged", resolved: "paged", prefillTokensSaved: 0)
        let result = BackendParityCriteria.prefixReuse(
            baseline: noneBase, candidate: noneCandidate)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("vacuous"))
    }

    /// Two arms whose ONLY difference is the saving, with a 1024-token
    /// structural allowance (paged bound 26624 vs contiguous 25600) — the
    /// real gemma-4 shape.
    private func reuseArms(
        baselineSaved: Int,
        candidateSaved: Int,
        candidateSupported: Bool = true
    ) -> (BackendParityObservation, BackendParityObservation) {
        func arm(
            _ selection: String, _ bound: Int, _ saved: Int, _ supported: Bool
        ) -> BackendParityObservation {
            BackendParityObservation(
                selection: selection, resolvedBackend: selection,
                prefixReuse: BackendParityObservation.PrefixReuse(
                    capabilitySupported: supported,
                    capabilityStrategy: supported ? "frozen_full_replay" : nil,
                    capabilityUnsupportedReason: supported
                        ? nil : "paged_hybrid_requires_dual_cursor",
                    replayBoundTokens: bound,
                    promptTokens: 28672,
                    donatedEntries: 1,
                    firstOutcome: "miss",
                    secondOutcome: saved > 0 ? "hit" : "adoption_failed",
                    secondMatchedTokens: 28416,
                    secondPrefillTokensSaved: saved))
        }
        return (
            arm("contiguous", 25600, baselineSaved, true),
            arm("paged", 26624, candidateSaved, candidateSupported)
        )
    }

    @Test("a shortfall of exactly one maxWindow is EXPECTED_SHORTFALL, not FAIL")
    func oneWindowShortfallIsExpected() {
        // The measured gemma-4 case: 2816 contiguous, 1792 paged, delta 1024,
        // which is exactly the maxWindow paged pays by construction.
        let (base, cand) = reuseArms(baselineSaved: 2816, candidateSaved: 1792)
        let result = BackendParityCriteria.prefixReuse(baseline: base, candidate: cand)
        #expect(result.verdict == .expectedShortfall)
        #expect(result.verdict != .pass)
        #expect(result.detail.contains("short by 1024"))
        // Percentage, because the same one-window cost is 36% here and 0.5%
        // on a short-window model.
        #expect(result.detail.contains("36.4%"))
        #expect(result.detail.contains("NOT a regression"))
        #expect(result.detail.contains("NOT parity"))
        #expect(result.detail.contains("maxWindow/matched"))
    }

    @Test("a shortfall beyond one maxWindow is a real FAIL and says by how much")
    func shortfallBeyondAllowanceFails() {
        let (base, cand) = reuseArms(baselineSaved: 2816, candidateSaved: 1791)
        let result = BackendParityCriteria.prefixReuse(baseline: base, candidate: cand)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("EXCEEDS the 1024-token structural allowance"))
    }

    @Test("an unsupported capability never hides inside the structural band")
    func unsupportedCapabilityCannotClaimTheAllowance() {
        // The allowance is the price of DOING frozen replay. A backend that
        // derived unsupported is not paying it, it is not reusing at all.
        let (base, cand) = reuseArms(
            baselineSaved: 1000, candidateSaved: 0, candidateSupported: false)
        let result = BackendParityCriteria.prefixReuse(baseline: base, candidate: cand)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("paged_hybrid_requires_dual_cursor"))
    }

    @Test("the shortfall percentage, not just the token count, reaches the reader")
    func shortfallMagnitudeIsAPercentage() {
        // The measured gpt-oss shape after F1's adoption fix: a 128-token
        // window against a 26880-token baseline saving — same structural cost
        // as gemma-4, two orders of magnitude less important.
        func arm(_ selection: String, _ bound: Int, _ saved: Int)
            -> BackendParityObservation
        {
            BackendParityObservation(
                selection: selection, resolvedBackend: selection,
                prefixReuse: BackendParityObservation.PrefixReuse(
                    capabilitySupported: true,
                    capabilityStrategy: "frozen_full_replay",
                    replayBoundTokens: bound,
                    promptTokens: 28672,
                    donatedEntries: 1,
                    firstOutcome: "miss",
                    secondOutcome: "hit",
                    secondMatchedTokens: 28416,
                    secondPrefillTokensSaved: saved))
        }
        let result = BackendParityCriteria.prefixReuse(
            baseline: arm("contiguous", 1536, 26880),
            candidate: arm("paged", 1664, 26752))
        #expect(result.verdict == .expectedShortfall)
        #expect(result.detail.contains("short by 128"))
        #expect(result.detail.contains("0.5%"))
    }

    @Test("a prefix that never got donated is UNAVAILABLE, not a missed reuse")
    func undonatedPrefixIsUnavailable() {
        // The harness failing to wait out the async donation would otherwise
        // read as a backend that cannot reuse — a fabricated regression.
        let stale = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            prefixReuse: BackendParityObservation.PrefixReuse(
                capabilitySupported: true,
                capabilityStrategy: "frozen_full_replay",
                replayBoundTokens: 26624,
                promptTokens: 28672,
                donatedEntries: 0,
                firstOutcome: "miss",
                secondOutcome: "miss"))
        let result = BackendParityCriteria.prefixReuse(baseline: baseline, candidate: stale)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("no prefix was donated"))
        #expect(result.detail.contains("paged"))
    }

    @Test("a probe prompt under the frozen-replay bound is UNAVAILABLE, not a failure")
    func belowReplayBoundIsUnavailable() {
        // gemma-4: 25 windowed layers x 1024 = 25600 contiguous, +maxWindow =
        // 26624 paged. A 1024-token probe measures the prompt, not the backend.
        func arm(_ selection: String, _ bound: Int) -> BackendParityObservation {
            BackendParityObservation(
                selection: selection, resolvedBackend: selection,
                prefixReuse: BackendParityObservation.PrefixReuse(
                    capabilitySupported: true,
                    capabilityStrategy: "frozen_full_replay",
                    replayBoundTokens: bound,
                    promptTokens: 1024,
                    donatedEntries: 4,
                    firstOutcome: "miss",
                    secondOutcome: "skipped_policy"))
        }
        let result = BackendParityCriteria.prefixReuse(
            baseline: arm("contiguous", 25600), candidate: arm("paged", 26624))
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("1024-token probe prompt"))
        #expect(result.detail.contains("26624"))
        #expect(result.detail.contains("--parity-prefix-tokens"))
        // Explicitly NOT the vacuous message: the reason is length, not workload.
        #expect(!result.detail.contains("vacuous"))
    }

    @Test("paged reusing at least as much as contiguous passes")
    func prefixReuseAtParityPasses() {
        let base = healthyArm(
            selection: "contiguous", resolved: "contiguous", prefillTokensSaved: 512)
        let equal = healthyArm(selection: "paged", resolved: "paged", prefillTokensSaved: 512)
        #expect(BackendParityCriteria.prefixReuse(baseline: base, candidate: equal).verdict
            == .pass)

        let better = healthyArm(selection: "paged", resolved: "paged", prefillTokensSaved: 768)
        #expect(BackendParityCriteria.prefixReuse(baseline: base, candidate: better).verdict
            == .pass)
    }

    @Test("an unmeasurable prefix arm is UNAVAILABLE with its reason")
    func prefixReuseUnmeasurableIsUnavailable() {
        let broken = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            prefixReuse: BackendParityObservation.PrefixReuse(
                unavailableReason: "prefix-cache engine construction failed"))
        let result = BackendParityCriteria.prefixReuse(baseline: baseline, candidate: broken)
        #expect(result.verdict == .unavailable)
        #expect(result.detail.contains("engine construction failed"))
    }

    // MARK: - Report assembly

    @Test("a healthy two-arm run produces five criteria and exits 0")
    func fullEvaluationPasses() {
        let criteria = BackendParityCriteria.evaluate(
            baseline: baseline, candidate: candidate)
        #expect(criteria.map(\.id) == [
            "token_exactness", "mtp_token_exactness", "packed_prefill",
            "vision_spans", "prefix_reuse",
        ])
        #expect(criteria.allSatisfy { $0.verdict == .pass })
        #expect(BackendParityOutcome(criteria: criteria).exitStatus == 0)
    }

    @Test("the report round-trips through JSON with its verdicts intact")
    func reportRoundTrips() throws {
        let report = BackendParityReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/tmp/gemma",
            assistantModelID: "gemma-4-26B-A4B-it-qat-assistant-4bit",
            arms: [baseline.arm, candidate.arm],
            criteria: BackendParityCriteria.evaluate(
                baseline: baseline, candidate: candidate),
            notes: ["resolved, not requested"])

        let decoded = try JSONDecoder().decode(
            BackendParityReport.self,
            from: Data(try report.jsonString().utf8))
        #expect(decoded.schemaVersion == BackendParityReport.currentSchemaVersion)
        #expect(decoded.modelID == report.modelID)
        #expect(decoded.assistantModelID == "gemma-4-26B-A4B-it-qat-assistant-4bit")
        #expect(decoded.arms.count == 2)
        #expect(decoded.arms[1].resolvedBackend == "paged")
        #expect(decoded.criteria.count == 5)
        #expect(decoded.criteria.allSatisfy { $0.verdict == .pass })
        #expect(decoded.outcome.exitStatus == 0)
    }

    @Test("an observation round-trips so a run can be replayed offline")
    func observationRoundTrips() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(candidate)
        let decoded = try JSONDecoder().decode(BackendParityObservation.self, from: data)
        #expect(decoded == candidate)
    }

    @Test("the operator table names every verdict and the summary line")
    func tableRendersVerdicts() {
        let refused = BackendParityObservation(
            selection: "paged", constructionFailure: "pagedUnavailable(\"no headroom\")")
        let report = BackendParityReport(
            modelID: "m", modelPath: "/tmp/m",
            arms: [baseline.arm, refused.arm],
            criteria: BackendParityCriteria.evaluate(baseline: baseline, candidate: refused))
        let table = report.renderTable()
        #expect(table.contains("arm paged -> resolved NOT BUILT"))
        #expect(table.contains("no headroom"))
        #expect(table.contains("[UNAVAILABLE]"))
        #expect(table.contains("G2 INCONCLUSIVE"))
    }
}

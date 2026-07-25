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
        #expect(outcome == .failed(criteria: ["mtp_token_exactness", "prefix_reuse"]))
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
        #expect(outcome == .passed(evaluated: 2, skipped: 0))
        #expect(outcome.exitStatus == 0)
        #expect(!outcome.summary.contains("partial"))
    }

    @Test("a partial pass exits 0 but says how much it could not measure")
    func partialPassAdvertisesSkips() {
        let outcome = BackendParityOutcome(criteria: [
            criterion(.tokenExactness, .pass),
            criterion(.packedPrefill, .unavailable),
            criterion(.visionSpans, .unavailable),
        ])
        #expect(outcome == .passed(evaluated: 1, skipped: 2))
        #expect(outcome.exitStatus == 0)
        #expect(outcome.summary.contains("partial"))
        #expect(outcome.summary.contains("2 UNAVAILABLE"))
    }

    @Test("the three outcomes have three distinct exit statuses")
    func statusesAreDistinguishable() {
        let statuses = Set([
            BackendParityOutcome.passed(evaluated: 1, skipped: 0).exitStatus,
            BackendParityOutcome.failed(criteria: ["x"]).exitStatus,
            BackendParityOutcome.nothingEvaluated(skipped: 3).exitStatus,
        ])
        #expect(statuses.count == 3)
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

    @Test("one differing token id fails and names the index and both ids")
    func tokenExactnessFailsOnDivergentID() {
        let healthy = candidate
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4, 99])],
            mtp: healthy.mtp, packedPrefill: healthy.packedPrefill,
            visionSpans: healthy.visionSpans, prefixReuse: healthy.prefixReuse)

        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("token 1"))
        #expect(result.detail.contains("5 vs 99"))
        #expect(result.measurements["divergence"] != nil)
    }

    @Test("identical ids but a different finish reason still fails")
    func tokenExactnessFailsOnFinishReason() {
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4, 5], finish: "length")])
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("finish reason"))
        #expect(result.detail.contains("stop vs length"))
    }

    @Test("a truncated stream fails rather than matching on its shared prefix")
    func tokenExactnessFailsOnPrefix() {
        let truncated = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: [row("a", [1, 2, 3]), row("b", [4])])
        let result = BackendParityCriteria.tokenExactness(
            baseline: baseline, candidate: truncated)
        #expect(result.verdict == .fail)
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

    @Test("an MTP divergence that the base decode already has is attributed to the base")
    func mtpDivergenceInheritedFromBaseDecodeIsLabelled() {
        // MTP verification emits the target's own argmaxes, so when plain
        // greedy decode already differs the MTP rows inherit it. Still a FAIL,
        // but blaming MTP would send someone to the wrong subsystem.
        let driftedRows = [row("a", [1, 2, 9]), row("b", [4, 5])]
        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: driftedRows,
            mtp: BackendParityObservation.MTP(
                rows: driftedRows,
                driverConstructed: true, rounds: 5, draftedTokens: 5, acceptedTokens: 3))
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("inherited from the base decode path"))
        #expect(result.detail.contains("fix token_exactness first"))
        #expect(result.measurements["inheritedFromBaseDecode"] != nil)
    }

    @Test("an MTP-only divergence is NOT labelled as inherited")
    func mtpOnlyDivergenceIsNotLabelledInherited() {
        // Base decode agrees; only the MTP rows differ. That IS an MTP defect.
        let mtpOnly = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: baseline.rows,
            mtp: BackendParityObservation.MTP(
                rows: [row("a", [1, 2, 9]), row("b", [4, 5])],
                driverConstructed: true, rounds: 5, draftedTokens: 5, acceptedTokens: 3))
        let result = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: mtpOnly)
        #expect(result.verdict == .fail)
        #expect(!result.detail.contains("inherited"))
        #expect(result.measurements["inheritedFromBaseDecode"] == nil)
    }

    @Test("MTP passes only when both arms drafted AND their token ids match")
    func mtpPassRequiresDraftsAndEquality() {
        let pass = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: candidate)
        #expect(pass.verdict == .pass)
        #expect(pass.detail.contains("both backends drafted"))

        let drifted = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            rows: candidate.rows,
            mtp: BackendParityObservation.MTP(
                rows: [row("a", [1, 2, 3]), row("b", [4, 77])],
                driverConstructed: true, rounds: 6, draftedTokens: 30, acceptedTokens: 21))
        let fail = BackendParityCriteria.mtpTokenExactness(
            baseline: baseline, candidate: drifted)
        #expect(fail.verdict == .fail)
        #expect(fail.detail.contains("MTP output diverged"))
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

    @Test("paged reusing less than contiguous fails and names the capability gap")
    func prefixReuseShortfallFails() {
        let base = healthyArm(
            selection: "contiguous", resolved: "contiguous", prefillTokensSaved: 768)
        let short = BackendParityObservation(
            selection: "paged", resolvedBackend: "paged",
            prefixReuse: BackendParityObservation.PrefixReuse(
                capabilitySupported: false,
                capabilityUnsupportedReason: "paged_hybrid_requires_dual_cursor",
                replayBoundTokens: 26624,
                promptTokens: 28672,
                donatedEntries: 4,
                firstOutcome: "disabled",
                secondOutcome: "disabled"))
        let result = BackendParityCriteria.prefixReuse(baseline: base, candidate: short)
        #expect(result.verdict == .fail)
        #expect(result.detail.contains("saved 0 prefill tokens against 768"))
        #expect(result.detail.contains("paged_hybrid_requires_dual_cursor"))
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

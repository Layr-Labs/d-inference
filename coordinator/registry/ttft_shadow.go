package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// Phase-0 SLA-aware, occupancy-aware admission — SHADOW + MEASUREMENT slice.
//
// This file holds the configuration and the read-only evaluator for the TTFT
// admission/spread shadow. It deliberately changes NO routing decision: in
// `off` (default) the evaluator is a no-op; in `shadow` (and, for now, `enforce`)
// it computes two signals against the winning candidate and hands them to the
// caller as fields on RoutingDecision, which the API layer emits as metrics.
//
//   - WouldShed: the occupancy-aware TTFT estimate
//     (occupancyAwareTTFTMsFromSnapshot = base + the occupancy term, which is
//     non-zero only when EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA > 0) for the chosen
//     provider exceeds the model's upstream deadline base (standard ~10s;
//     exact-model policies may be shorter). This is NOT the live coordinator
//     cutoff, which preserves response headroom inside the upstream SLA. The
//     occupancy term is intentionally confined to this shadow estimate so it can
//     never tighten the live HARD_REJECT ceiling fed by ttftMsFromSnapshot.
//   - IdleAlternativeExists: the chosen provider already carries occupying peers
//     while an instantly-usable (loaded, zero-occupancy) provider for the same
//     model was routable — the load-SPREADING failure the data shows (idle loaded
//     boxes coexisted with 100% of the gpt-oss cancels).
//
// The shadow reuses the occupancy the snapshot ALREADY tracks (snapshotOccupancy
// = max(pendingForModel, backend_running+backend_waiting)); it does NOT introduce
// a parallel reservation counter.

// ttftShadowEval is the result of the read-only Phase-0 evaluation. It is copied
// onto RoutingDecision (applyTo) so the API layer can emit metrics without the
// registry importing the telemetry package.
type ttftShadowEval struct {
	Evaluated             bool
	Mode                  string
	WouldShed             bool
	IdleAlternativeExists bool
	EstimateMs            float64
	DeadlineMs            float64
	Occupancy             int
}

func (e ttftShadowEval) applyTo(d *RoutingDecision) {
	if d == nil || !e.Evaluated {
		return
	}
	d.ShadowEvaluated = true
	d.ShadowMode = e.Mode
	d.ShadowWouldShed = e.WouldShed
	d.ShadowIdleAlternativeExists = e.IdleAlternativeExists
	d.ShadowEstimateMs = e.EstimateMs
	d.ShadowDeadlineMs = e.DeadlineMs
	d.ShadowOccupancy = e.Occupancy
}

// evaluateTTFTShadowLocked computes the Phase-0 shadow signals for the winning
// candidate WITHOUT changing the routing decision. Returns the zero value (a
// no-op for applyTo) when the admission mode is off.
//
// Caller holds r.mu and no provider lock. scan is the exact post-narrowing pool
// that produced winner, so the idle-spread signal reuses it instead of walking
// the fleet a second time. winner.snapshot is the PRE-reserve snapshot, so its
// occupancy excludes the request about to be admitted (the b, not b+1, the new
// request actually waits behind).
func (r *Registry) evaluateTTFTShadowLocked(
	model string,
	pr *PendingRequest,
	winner *routingCandidate,
	scan candidateScan,
) ttftShadowEval {
	mode := routingPolicy.TTFTAdmissionModeValue()
	if mode == TTFTAdmissionOff || winner == nil || pr == nil {
		return ttftShadowEval{}
	}
	reqPrompt := pr.EstimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}
	snap := &winner.snapshot
	// Occupancy-aware estimate (base + occupancy term). The occupancy term lives
	// here, in the SHADOW path only — ttftMsFromSnapshot (the live cost / ceiling /
	// bestTTFT input) stays occupancy-free so raising alpha cannot tighten the
	// live request-local HARD_REJECT ceiling. See occupancyAwareTTFTMsFromSnapshot.
	estimate := routingPolicy.OccupancyAwareTTFTMs(snap, reqPrompt)
	deadline := routingPolicy.ShadowDeadlineMs(model, reqPrompt)
	occ := routingcost.Occupancy(snap)

	eval := ttftShadowEval{
		Evaluated: true,
		Mode:      mode.String(),
		// Providers without BackendCapacity have no reliable TTFT estimate
		// (ttftMsFromSnapshot returns 0), so they never "would_shed" — matching
		// the live ceiling's behavior.
		WouldShed:  snap.HasBackendCapacity && estimate > deadline,
		EstimateMs: estimate,
		DeadlineMs: deadline,
		Occupancy:  occ,
	}
	// The spread signal only makes sense when the winner is itself herded: if we
	// already routed to an idle box (occ == 0) there was nothing better to spread
	// to. When herded, check whether an instantly-usable loaded-idle peer for the
	// same model was routable.
	if occ > 0 {
		eval.IdleAlternativeExists = loadedIdleAlternativeExistsFromScan(scan, winner.provider)
	}
	return eval
}

// loadedIdleAlternativeExistsFromScan derives the shadow spread signal from the
// selector's already-filtered pool. The scan and its snapshots are immutable.
func loadedIdleAlternativeExistsFromScan(scan candidateScan, winner *Provider) bool {
	winnerID := ""
	if winner != nil {
		winnerID = winner.ID
	}
	for _, candidate := range scan.pool {
		if candidate.provider == nil || candidate.provider.ID == winnerID {
			continue
		}
		if candidate.snapshot.ModelLoaded && routingcost.Occupancy(&candidate.snapshot) == 0 {
			return true
		}
	}
	return false
}

// loadedIdleAlternativeExistsLocked reports whether some provider OTHER than the
// winner is an instantly-usable (model-resident, zero-occupancy) spread target
// the herded request could have been routed to instead.
//
// It derives eligibility from the SAME computation the selector uses
// (scanCandidatesLocked — the single source of routing eligibility: every
// per-provider gate AND the post-candidate pool narrowing, i.e.
// exclude/self-route/allowlist/vision/capacity/TTFT-ceiling + prefer-owner +
// AvoidVersion + MinDecodeTPS), then checks whether any resulting eligible
// candidate other than the winner is loaded-idle. Because it reuses the
// selector's pool rather than re-deriving the gates, the Phase-0 spread metric
// can never count a peer the scheduler would have rejected. Caller holds r.mu and
// no provider lock.
func (r *Registry) loadedIdleAlternativeExistsLocked(model string, pr *PendingRequest, winner *Provider, excludeIDs ...string) bool {
	return loadedIdleAlternativeExistsFromScan(
		r.scanCandidatesLocked(model, pr, false, excludeIDs...), winner)
}

// currentTTFTShadow recomputes the observational signal from the winner's
// commit-time pre-reserve snapshot and a fresh, shared-lock candidate pool. It
// runs after the pending debit is committed, so concurrent reservations cannot
// leave occupancy and idle-alternative telemetry pinned to the original scan.
func (r *Registry) currentTTFTShadow(
	model string,
	pr *PendingRequest,
	winner *routingCandidate,
	excludeIDs ...string,
) ttftShadowEval {
	if TTFTAdmissionModeValue() == TTFTAdmissionOff || winner == nil || pr == nil {
		return ttftShadowEval{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	var current candidateScan
	if routingcost.Occupancy(&winner.snapshot) > 0 {
		current = r.scanCandidatesLocked(model, pr, false, excludeIDs...)
	}
	return r.evaluateTTFTShadowLocked(model, pr, winner, current)
}

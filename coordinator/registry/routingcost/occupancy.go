package routingcost

// Policy.OccupancyAwareTTFTMs is the occupancy-aware TTFT estimate: the base
// estimate (RawTTFTMs — what the LIVE cost / MaxTTFTMs ceiling / bestTTFT
// consume) PLUS the Phase-0 head-of-line occupancy term (Policy.OccupancyMs, gated by
// EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA).
//
// It is used ONLY by the shadow evaluator today; a future enforce step will wire
// it (against the verified ~10s base) into the live path. Keeping the occupancy
// term OUT of RawTTFTMs is a SAFETY INVARIANT: prod runs HARD_REJECT
// (pr.MaxTTFTMs set from the pinned request-local deadline), so if the term
// leaked into RawTTFTMs, raising alpha would tighten the live ceiling
// and over-shed ~2x (telemetry-db findings §2). The term may therefore only
// ever reach the shadow estimate, never breakdown.TTFTMs.
func (policy *Policy[Connection]) OccupancyAwareTTFTMs(snap *Snapshot[Connection], reqPromptTokens int) float64 {
	base := RawTTFTMs(snap, reqPromptTokens)
	if base <= 0 {
		// No reliable base (provider without BackendCapacity) → no occupancy-aware
		// estimate either, matching RawTTFTMs's contract.
		return base
	}
	return base + policy.OccupancyMs(snap)
}

// Policy.OccupancyMs is the Phase-0 occupancy term: the head-of-line wait while the
// box's already-occupying work (the herd) clears enough for a newly admitted
// request to emit its first token. The base estimate (RawTTFTMs) counts
// only WAITING prefill and a single decode step, so it is flat in running
// occupancy — exactly where the ~11s of "dark time" lives. It is added ONLY in
// Policy.OccupancyAwareTTFTMs (the shadow estimate), never in the live
// RawTTFTMs.
//
// The term reuses the occupancy the snapshot ALREADY carries
// (Occupancy = max(pendingForModel, backend_running+backend_waiting)),
// not a new parallel counter, so it is herd-aware for free: a burst onto a box
// still reporting backend_running=0 shows up through pendingForModel. Magnitude
// per occupying peer is alpha decode-token-times divided by the per-request
// decode rate the new request will actually see — projected at the SAME occupancy
// (occ), not the stale backend_running gauge, so in the herd case (pendingForModel
// > backend_running) it is charged the contended rate, not an idle-batch rate.
// The rate itself shrinks with occ, making the term super-linear in occupancy.
//
// Returns 0 when EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA is 0 (the default) or
// occupancy is 0 (an idle box never pays the term, so route-to-idle is
// preserved). The deadline this is gated against in the shadow evaluator is the
// model's upstream SLA (standard ~10s), not the shorter live coordinator cutoff.
// Conflating those clocks over-sheds (telemetry-db findings §2).
func (policy *Policy[Connection]) OccupancyMs(snap *Snapshot[Connection]) float64 {
	alpha := policy.ttftOccupancyAlpha
	if alpha <= 0 {
		return 0
	}
	occ := Occupancy(snap)
	if occ <= 0 {
		return 0
	}
	// Project the per-request rate at the batch the request ACTUALLY joins (occ),
	// not the bare heartbeat backend_running: in the herd case the new request
	// waits behind occ peers, so charging the idle/low-batch rate would under-
	// state the term in exactly the case it exists to catch.
	perReqDecodeTPS := ProjectedPerRequestDecodeTPSAtBatch(snap, occ)
	if perReqDecodeTPS <= 0 {
		perReqDecodeTPS = 1.0
	}
	return alpha * float64(occ) * 1000.0 / perReqDecodeTPS
}

package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// chipClassKey keys the solo-sample store at a FINER grain than ChipFamily
// alone: an M4 Max and an M4 Pro are the same family but 3–4× apart in decode
// throughput, so pooling them by family lets a fast tier's rate raise a slow
// tier's quality cap — the exact over-admission this cap exists to prevent.
// The class is ChipFamily|ChipTier (e.g. "M4|Max"); the raw ChipName is the
// fallback when the family is absent. Byte-for-byte the form #526's
// prefillChipClass uses, so the solo and prefill rings key identically.
func chipClassKey(hw protocol.Hardware) string {
	if hw.ChipFamily == "" {
		return hw.ChipName
	}
	return hw.ChipFamily + "|" + hw.ChipTier
}

// soloSampleEligible reports whether a heartbeat's capacity snapshot qualifies
// as an uncontended box for SOLO sampling: the whole box — every slot, every
// co-resident model — has at most one running-or-waiting request. The ≤1
// allowance is the request that produced the EWMA itself; ANY other activity
// anywhere on the box disqualifies, which is exactly what keeps mixed-box
// samples honest (a gemma EWMA measured while gpt-oss batches on the same GPU
// is a contended rate, not a solo one). This is the BOX-level half of the
// gate; the heartbeat ingest additionally records only a slot with an actual
// running decode (NumRunning > 0), so neither an idle co-resident slot nor a
// purely-queued box can re-report a stale decayed EWMA as a fresh solo
// observation every heartbeat. Negative counts (already clamped upstream by
// clampBackendCapacity) are defensively ignored.
func soloSampleEligible(bc *protocol.BackendCapacity) bool {
	if bc == nil {
		return false
	}
	load := 0
	for _, slot := range bc.Slots {
		if n := slot.NumRunning + slot.NumWaiting; n > 0 {
			load += n
		}
		if load > 1 {
			return false
		}
	}
	return true
}

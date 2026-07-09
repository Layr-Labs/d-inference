package registry

import (
	"sort"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// solo_tps.go is the solo-gated half of TPSRegistry: per-(model, chip) decode
// rates sampled ONLY while the reporting box was uncontended, so a mixed box's
// gemma sample is never smeared by a concurrent gpt-oss batch. These medians
// are the per-model static rate the quality-concurrency cap consumes
// (resolvedSoloModelTPSLocked, concurrency_cap.go) — the root fix for the
// 2026-07-06 gemma postmortem layer 6, where the cap read the provider-LEVEL
// registration benchmark (gpt-oss 58–93 tok/s) and granted gemma caps of
// 12–23 on boxes where gemma actually decodes 10–18 solo.
//
// The load-inclusive store (Record/Median, tps_registry.go) is untouched: its
// consumers (fleetMedianTPS → TTFT estimation) want under-load samples.

// RecordSolo adds a solo (uncontended-box) decode TPS sample for the given
// model and chip family. Callers must pre-gate on soloSampleEligible AND on
// the slot having an actual running decode (NumRunning > 0, see the heartbeat
// ingest in registry.go) so a purely-queued box's retained EWMA is not
// sampled — this method itself only validates the sample value, mirroring
// Record.
func (r *TPSRegistry) RecordSolo(model, chipFamily string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.Lock()
	defer r.mu.Unlock()
	samples := r.soloSamples[key]
	if len(samples) >= r.maxSamples {
		// Drop oldest sample (FIFO ring), same shape as Record.
		samples = samples[1:]
	}
	r.soloSamples[key] = append(samples, tps)
}

// SoloMedian returns the median solo decode TPS for the given model and chip
// family plus the number of samples behind it. (0, 0) when no solo samples
// exist. The count lets callers apply a min-sample trust floor before using
// the median for admission decisions.
func (r *TPSRegistry) SoloMedian(model, chipFamily string) (float64, int) {
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.RLock()
	samples := r.soloSamples[key]
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	r.mu.RUnlock()
	return medianOfCopied(sorted), len(sorted)
}

// SoloMedianAllChips returns the model-wide solo median pooled across every
// chip family that has at least one solo sample, plus the total sample count.
// It is the conservative cross-chip transfer used when a specific (model,
// chip) pair has too few samples: some real solo measurement of the model
// beats a provider-level benchmark taken on a different model.
func (r *TPSRegistry) SoloMedianAllChips(model string) (float64, int) {
	r.mu.RLock()
	var pooled []float64
	for key, samples := range r.soloSamples {
		if key.Model != model {
			continue
		}
		pooled = append(pooled, samples...)
	}
	r.mu.RUnlock()
	return medianOfCopied(pooled), len(pooled)
}

// medianOfCopied returns the median of samples, sorting in place (callers pass
// a private copy). 0 for an empty slice.
func medianOfCopied(sorted []float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
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

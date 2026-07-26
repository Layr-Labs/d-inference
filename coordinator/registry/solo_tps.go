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

// RecordSolo adds a solo (uncontended-box) decode TPS sample for the given
// model and chip CLASS (chipClassKey — family+tier, not family alone). Callers
// must pre-gate on soloSampleEligible AND on the slot having an actual running
// decode (NumRunning > 0, see the heartbeat ingest in registry.go) so a
// purely-queued box's retained EWMA is not sampled — this method itself only
// validates the sample value, mirroring Record. The tpsKey.ChipFamily field
// carries the chip-class string for solo entries.
func (r *TPSRegistry) RecordSolo(model, chipClass string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipClass}
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
// CLASS (chipClassKey) plus the number of samples behind it. (0, 0) when no
// solo samples exist. The count lets callers apply a min-sample trust floor
// before using the median for admission decisions.
func (r *TPSRegistry) SoloMedian(model, chipClass string) (float64, int) {
	key := tpsKey{Model: model, ChipFamily: chipClass}
	r.mu.RLock()
	samples := r.soloSamples[key]
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	r.mu.RUnlock()
	return medianOfCopied(sorted), len(sorted)
}

// SoloMedianAllChips is the CONSERVATIVE cross-class transfer used when a
// provider's own chip class has too few solo samples: it returns the MINIMUM
// of the per-class medians across every chip class that has at least one solo
// sample for the model, the TOTAL sample count across those classes, and the
// number of CLASSES that contributed a positive median.
//
// SAFETY INVARIANT: the resolver must never hand a slow box a rate faster than
// its own class demonstrated. Pooling every sample into one median (the old
// behavior) lets a fast, sample-heavy class dominate and return a rate above a
// slow box's real capability — over-capping it into the very quality collapse
// this cap prevents. Taking the min of per-class medians instead can never
// exceed the slowest class's typical rate: worst case it UNDER-caps a fast box
// (safe, quality-protective), never over-caps a slower one.
//
// That invariant has a precondition the resolver must check, which is why the
// class count is returned: the minimum is only a CROSS-CLASS bound when more
// than one class contributed. With a single sampled class the "min" is just
// that one class's own median wearing the name of a minimum, and handing it to
// a provider of a different, unsampled class bounds nothing at all — one M4
// Max sample would set an unsampled M1 Pro's rate. See
// resolvedSoloModelTPSLocked, which refuses that transfer unless a seed or the
// provider's own samples bound it.
//
// The total sample count keeps the resolver's >= qualityCapSoloMinSamples trust
// floor unchanged. The tpsKey.ChipFamily field carries the chip-class string
// for solo entries, so grouping by key.Model + key.ChipFamily groups by class.
func (r *TPSRegistry) SoloMedianAllChips(model string) (tps float64, samples, classes int) {
	r.mu.RLock()
	perClass := make(map[string][]float64)
	for key, s := range r.soloSamples {
		if key.Model != model || len(s) == 0 {
			continue
		}
		// append copies the values, so perClass is safe to sort after RUnlock.
		perClass[key.ChipFamily] = append(perClass[key.ChipFamily], s...)
	}
	r.mu.RUnlock()

	minMedian, total, classCount := 0.0, 0, 0
	for _, s := range perClass {
		// s is a private copy; medianOfCopied sorts it in place.
		m := medianOfCopied(s)
		total += len(s)
		if m <= 0 {
			continue
		}
		if classCount == 0 || m < minMedian {
			minMedian = m
		}
		classCount++
	}
	return minMedian, total, classCount
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

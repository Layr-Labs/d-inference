package registry

import "github.com/eigeninference/d-inference/coordinator/env"

// prefill_tps.go is the observed-prefill half of TPSRegistry: per-(model, chip
// family) medians of the prefill EWMAs providers report in heartbeats
// (BackendSlotCapacity.ObservedPrefillTPS, populated by v0.7.5's bridge usage
// timings). These medians are the prefill-honest input to the TTFT estimate
// (prefillTPSForSnapshot, prefill_fallback.go): today an unmeasured provider's
// prefill is estimated as decode×EIGENINFERENCE_PREFILL_DECODE_RATIO
// (sqrt-bandwidth×12 ≈ 280 tok/s) — ~23× below the measured fleet reality
// (p50 6,523 tok/s) — so gpt-oss's 13.7k-token p90 prompts predict ~38s TTFT
// against a 5s deadline and 18.2k requests/day die on ttft_too_slow
// mispredictions. A per-(model, chip) median of REAL measurements replaces
// that guess for every box of the same chip family, including boxes that
// haven't (or can't yet) report their own measurement.
//
// Ingest gating — decided against solo-gating, differing from the solo decode
// ring on purpose:
//
//   - Prefill throughput is per-request compute-bound work (a parallel batched
//     pass over the prompt), not the shared-decode-loop rate the solo gate
//     protects; co-resident decode steals some GPU time but does not collapse
//     the measurement the way batching collapses per-request decode.
//   - The known garbage mode (PR #453's analysis): the admitted→first-token
//     window collapsing on a prefix-cache hit inflates the EWMA to absurd
//     values. That is handled upstream of this ring — clampBackendCapacity
//     zeroes out-of-range values (> maxPrefillTPS, raised to 20,000 above the
//     measured p90 so REAL measurements survive ingest), and the provider-side
//     fix samples cold prefills only — so samples reaching RecordPrefill are
//     already sanity-bounded.
//   - Re-reports are deduplicated at the heartbeat ingest, not here: the slot
//     EWMA is persistent and resent every 30s, so Heartbeat records a sample
//     only when the reported value CHANGED since the connection's last recorded
//     one (Provider.lastRecordedPrefillTPS) — otherwise one idle box's single
//     cold-prefill measurement would satisfy the min-sample floor below after
//     five ticks of the same value. Residual contamination (mild under-load
//     smear) is absorbed by the same defenses the decode rings rely on:
//     per-(model, chip) keying makes same-chip samples roughly exchangeable,
//     the median is rank-robust, the min-sample floor delays trust, and the
//     #512 online TTFT calibrator remains downstream as the corrector for any
//     residual bias.
//
// Two knobs, both live-read (no restart, mirroring decodeFloorUseFleetMedian):
//
//   - EIGENINFERENCE_TTFT_PREFILL_MEDIANS (bool, default true): kill switch;
//     false removes the median layer and restores the pure ratio-derived path
//     (plus the #453 fallback anchor, whose own mode env governs it).
//   - EIGENINFERENCE_TTFT_PREFILL_MIN_SAMPLES (int, default 5): samples
//     required before a (model, chip) median is trusted by the TTFT estimate.
//
// There is deliberately NO cross-chip pooled fallback (unlike the solo-cap
// resolver): prefill is compute-bound and spreads 3–4× across chip tiers, so a
// cross-chip transfer could over-admit a slow tier at the hard TTFT gate. With
// too few same-chip samples the estimate falls back to the ratio chain / #453
// anchor instead.

const (
	ttftPrefillMediansEnv    = env.EnvPrefix + "_TTFT_PREFILL_MEDIANS"
	ttftPrefillMinSamplesEnv = env.EnvPrefix + "_TTFT_PREFILL_MIN_SAMPLES"
)

// defaultTTFTPrefillMinSamples is the trust floor when
// EIGENINFERENCE_TTFT_PREFILL_MIN_SAMPLES is unset.
const defaultTTFTPrefillMinSamples = 5

// ttftPrefillMediansEnabled gates the per-(model, chip) prefill-median layer of
// the TTFT prefill estimate. Read LIVE (no restart); default ON. Set
// EIGENINFERENCE_TTFT_PREFILL_MEDIANS=false to restore the pure ratio-derived
// path exactly.
func ttftPrefillMediansEnabled() bool {
	return env.EnvBool(ttftPrefillMediansEnv, true)
}

// ttftPrefillMinSamples returns the minimum sample count before a prefill
// median is trusted. Read live; values < 1 are floored to 1.
func ttftPrefillMinSamples() int {
	n := env.EnvInt(ttftPrefillMinSamplesEnv, defaultTTFTPrefillMinSamples)
	if n < 1 {
		n = 1
	}
	return n
}

// RecordPrefill adds an observed prefill TPS sample for the given model and
// chip family. Called from heartbeat processing when a provider reports
// slot.ObservedPrefillTPS > 0 (post-clamp, so out-of-range garbage was already
// zeroed and never reaches the ring) AND the value changed since the
// connection's last recorded sample (the heartbeat-side re-report dedup —
// Provider.lastRecordedPrefillTPS). Load-inclusive like Record — see the file
// comment for why prefill samples are not solo-gated.
func (r *TPSRegistry) RecordPrefill(model, chipFamily string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.Lock()
	defer r.mu.Unlock()
	samples := r.prefillSamples[key]
	if len(samples) >= r.maxSamples {
		// Drop oldest sample (FIFO ring), same shape as Record/RecordSolo.
		samples = samples[1:]
	}
	r.prefillSamples[key] = append(samples, tps)
}

// PrefillMedian returns the median observed prefill TPS for the given model
// and chip family plus the number of samples behind it. (0, 0) when no samples
// exist. The count lets the TTFT estimate apply the min-sample trust floor.
func (r *TPSRegistry) PrefillMedian(model, chipFamily string) (float64, int) {
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.RLock()
	samples := r.prefillSamples[key]
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	r.mu.RUnlock()
	return medianOfCopied(sorted), len(sorted)
}

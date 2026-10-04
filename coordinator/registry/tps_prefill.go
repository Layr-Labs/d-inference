package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// tps_prefill.go is the isolated-prefill half of TPSRegistry. It keeps the
// same 50-sample ring per model and chip family as the decode store, and the
// heartbeat feeds it at the same point. Routing reads PrefillMedian only to
// price a provider that evidence exploration admits
// (first_content_exploration_pricing.go).

// RecordPrefill adds an isolated prefill rate for the model and chip family.
func (r *TPSRegistry) RecordPrefill(model, chipFamily string, tps float64) {
	if !finitePositive(tps) || tps > maxPrefillTPS || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.prefillSamples == nil {
		r.prefillSamples = make(map[tpsKey][]float64)
	}
	if r.prefillMedians == nil {
		r.prefillMedians = make(map[tpsKey]float64)
	}
	samples := appendRingSample(r.prefillSamples[key], tps, r.maxSamples)
	r.prefillSamples[key] = samples
	r.prefillMedians[key] = r.medianOfRingLocked(samples)
}

// PrefillMedian returns the median isolated prefill rate for the model and
// chip family. It returns 0 when there are no samples.
func (r *TPSRegistry) PrefillMedian(model, chipFamily string) float64 {
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.RLock()
	median := r.prefillMedians[key]
	r.mu.RUnlock()
	return median
}

// slotIsolatedPrefillTPS returns the slot's usable isolated prefill rate. It
// applies the rule that fillFirstContentSnapshot uses: an explicit
// measurement replaces the legacy EWMA, and the legacy EWMA counts only when
// the provider marks it initialized.
func slotIsolatedPrefillTPS(slot *protocol.BackendSlotCapacity) (float64, bool) {
	t := slot.Telemetry
	if t == nil {
		return 0, false
	}
	if m := slot.PerformanceMeasurements; m != nil {
		if !validPerformanceObservation(m.IsolatedPrefill) {
			return 0, false
		}
		return m.IsolatedPrefill.TokensPerSecond, true
	}
	if t.EWMAInitialized == nil || !*t.EWMAInitialized || t.IsolatedPrefillTPS == nil ||
		!finitePositive(*t.IsolatedPrefillTPS) || *t.IsolatedPrefillTPS > maxPrefillTPS {
		return 0, false
	}
	return *t.IsolatedPrefillTPS, true
}

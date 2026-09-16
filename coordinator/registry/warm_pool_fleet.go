package registry

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/warmpool"
)

func (r *Registry) warmPoolFleetSnapshot(now time.Time) map[string]warmPoolModelSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]warmPoolModelSnapshot)
	// Per-model rate samples (from every eligible provider serving the model,
	// warm or warmable) collapsed to a representative median at the end.
	// decodeSamples carries the quality-cap solo rate (→ qualityConcurrency);
	// serviceSamples the observed-EWMA service rate (→ E[S]).
	decodeSamples := make(map[string][]float64)
	serviceSamples := make(map[string][]float64)
	prefillSamples := make(map[string][]float64)
	concSamples := make(map[string][]float64)
	for _, p := range r.providers {
		p.mu.Lock()
		models := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			if r.providerModelAllowedByCatalogLocked(p, m) {
				models = append(models, m.ID)
			}
		}
		for _, model := range models {
			warm := r.providerHasWarmModelLocked(p, model, now)
			s := out[model]
			s.Model = model
			if warm {
				s.Warm++
				running, waiting := warmPoolModelLoadLocked(p, model)
				s.Running += running
				s.Waiting += waiting
				if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) || warmPoolBackendSlotBusyLocked(p) {
					s.WarmSaturated++
					// Only foreign load is missing from this model's running/waiting
					// counts; adding self-saturated providers would double-count it.
					if running+waiting == 0 {
						s.WarmForeignBlocked++
					}
				}
			} else {
				candidate, reason := r.warmPoolCandidateReasonLocked(p, model, now)
				if reason != warmColdEligible {
					if s.ColdDisqualifiers == nil {
						s.ColdDisqualifiers = make(map[warmColdReason]int)
					}
					s.ColdDisqualifiers[reason]++
					s.ColdIneligible++
					out[model] = s
					continue
				}
				s.EligibleCold = append(s.EligibleCold, candidate)
			}
			out[model] = s
			// Both warm and eligible-cold providers contribute to the same cohort.
			// The static solo resolver matches admission's quality cap; the observed
			// service rate separately estimates the duration a request will see.
			serviceTPS, prefillTPS := resolvedModelTPSLocked(p, model)
			decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
			serviceSamples[model] = append(serviceSamples[model], serviceTPS)
			prefillSamples[model] = append(prefillSamples[model], prefillTPS)
			concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
		}
		p.mu.Unlock()
	}
	for model, s := range out {
		sort.Slice(s.EligibleCold, func(i, j int) bool { return s.EligibleCold[i].Score > s.EligibleCold[j].Score })
		s.SoloDecodeTPS = warmpool.Median(decodeSamples[model])
		s.ServiceDecodeTPS = warmpool.Median(serviceSamples[model])
		s.PrefillTPS = warmpool.Median(prefillSamples[model])
		s.MaxProviderConc = int(warmpool.Median(concSamples[model]))
		out[model] = s
	}
	return out
}

// warmPoolModelLoadLocked returns the in-flight (NumRunning) and provider-queued
// (NumWaiting) request counts for the model on this provider, read from the
// authoritative BackendCapacity slot. Caller must hold p.mu.
func warmPoolModelLoadLocked(p *Provider, model string) (running, waiting int) {
	if p.BackendCapacity == nil {
		return 0, 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model {
			return slot.NumRunning, slot.NumWaiting
		}
	}
	return 0, 0
}

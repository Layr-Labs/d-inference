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
			if warm {
				s := out[model]
				s.Model = model
				s.Warm++
				running, waiting := warmPoolModelLoadLocked(p, model)
				s.Running += running
				s.Waiting += waiting
				if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) || warmPoolBackendSlotBusyLocked(p) {
					s.WarmSaturated++
					// Saturated while serving NONE of this model's requests means
					// a co-resident model is holding the capacity. That load is
					// invisible in s.running/s.waiting, so the warm-pool target
					// must not treat this provider as usable capacity for this
					// model (see headroomTarget).
					if running+waiting == 0 {
						s.WarmForeignBlocked++
					}
				}
				out[model] = s
				// decodeSamples feed soloDecodeTPS → qualityConcurrency in the
				// warm target. Use the SAME solo resolver as the admission cap
				// (solo median / seed → provider benchmark), NOT the per-slot
				// observed EWMA: the EWMA is a contended rate, and planning warm
				// targets from it while admission caps from the solo rate would
				// let the two disagree. The observed-EWMA chain
				// (resolvedModelTPSLocked) still feeds serviceSamples/prefill —
				// E[S] wants the load-inclusive rate a request actually sees.
				serviceTPS, prefillTPS := resolvedModelTPSLocked(p, model)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
				continue
			}
			candidate, reason := r.warmPoolCandidateReasonLocked(p, model, now)
			s := out[model]
			s.Model = model
			if reason == warmColdEligible {
				s.EligibleCold = append(s.EligibleCold, candidate)
				out[model] = s
				// Same solo-resolver / service-rate split as the warm branch above.
				serviceTPS, prefillTPS := resolvedModelTPSLocked(p, model)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
			} else {
				if s.ColdDisqualifiers == nil {
					s.ColdDisqualifiers = make(map[warmColdReason]int)
				}
				s.ColdDisqualifiers[reason]++
				s.ColdIneligible++
				out[model] = s
			}
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

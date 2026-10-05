package registry

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

func (r *Registry) warmPoolFleetSnapshot(now time.Time) map[string]warmplan.Fleet {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]warmplan.Fleet)
	// Per-model rate samples (from every eligible provider serving the model,
	// warm or warmable) collapsed to a representative median at the end.
	// decodeSamples carries the quality-cap solo rate (→ qualityConcurrency);
	// serviceSamples the observed-EWMA service rate (→ E[S]).
	decodeSamples := make(map[string][]float64)
	serviceSamples := make(map[string][]float64)
	prefillSamples := make(map[string][]float64)
	concSamples := make(map[string][]float64)
	qualitySamples := make(map[string][]float64)
	aggregateSamples := make(map[string][]float64)
	params := warmplan.TargetParams{LoadFactorK: effectiveTPSLoadFactor, FallbackQualityConcurrency: 1}
	if r.warmPool != nil {
		params = r.warmPool.targetParams()
	}
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
				serviceTPS, _ := resolvedModelTPSLocked(p, model)
				quality, aggregate, prefillTPS := r.warmPoolCapacityLocked(p, model, params)
				qualitySamples[model] = append(qualitySamples[model], float64(quality))
				aggregateSamples[model] = append(aggregateSamples[model], aggregate)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
				continue
			}
			candidate, reason := r.warmPoolCandidateReasonLocked(p, model, now)
			s := out[model]
			s.Model = model
			if reason == warmplan.WarmColdEligible {
				s.EligibleCold = append(s.EligibleCold, candidate)
				out[model] = s
				// Same solo-resolver / service-rate split as the warm branch above.
				serviceTPS, _ := resolvedModelTPSLocked(p, model)
				quality, aggregate, prefillTPS := r.warmPoolCapacityLocked(p, model, params)
				qualitySamples[model] = append(qualitySamples[model], float64(quality))
				aggregateSamples[model] = append(aggregateSamples[model], aggregate)
				decodeSamples[model] = append(decodeSamples[model], r.resolvedSoloModelTPSLocked(p, model).tps)
				serviceSamples[model] = append(serviceSamples[model], serviceTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
			} else {
				if s.ColdDisq == nil {
					s.ColdDisq = make(map[warmplan.ColdReason]int)
				}
				s.ColdDisq[reason]++
				s.ColdIneligible++
				out[model] = s
			}
		}
		p.mu.Unlock()
	}
	for model, s := range out {
		sort.Slice(s.EligibleCold, func(i, j int) bool {
			a, b := s.EligibleCold[i], s.EligibleCold[j]
			if a.RecentResidentModels != b.RecentResidentModels {
				return a.RecentResidentModels < b.RecentResidentModels
			}
			if a.Score != b.Score {
				return a.Score > b.Score
			}
			return a.ProviderID < b.ProviderID
		})
		s.SoloDecodeTPS = warmplan.MedianFloat(decodeSamples[model])
		s.ServiceDecodeTPS = warmplan.MedianFloat(serviceSamples[model])
		s.PrefillTPS = warmplan.MedianFloat(prefillSamples[model])
		s.MaxProviderConc = int(warmplan.MedianFloat(concSamples[model]))
		s.QualityConc = max(1, int(warmplan.MedianFloat(qualitySamples[model])))
		s.AggregateDecodeTPS = warmplan.MedianFloat(aggregateSamples[model])
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

// warmPoolCandidateReasonLocked returns the candidate and any disqualification
// reason for instrumentation. Caller holds r.mu + p.mu.
func (r *Registry) warmPoolCandidateReasonLocked(p *Provider, model string, now time.Time) (warmplan.Candidate, warmplan.ColdReason) {
	return (&ModelLoadPreparation{registry: r}).coldCandidateLocked(p, model, now)
}

func warmPoolBackendSlotBusyLocked(p *Provider) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.NumRunning > 0 || slot.NumWaiting > 0 {
			return true
		}
	}
	return false
}

func (r *Registry) pendingModelLoadCount(now time.Time) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pendingLoads.Expire(now, func(key pendingload.Key) {
		r.recordDeadlineLoadActivityLocked(key.ProviderID, now)
	})
	return r.pendingLoads.Count()
}

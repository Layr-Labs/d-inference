package registry

import (
	"math"
	"strings"
)

// qualityCapOvercommitForModelLocked resolves the overcommit for a model: the
// per-model override when one exists for the resolved build id, else the global
// value. Caller holds r.mu.
func (r *Registry) qualityCapOvercommitForModelLocked(model string) float64 {
	if v, ok := qualityCapOvercommitByModel[strings.ToLower(model)]; ok {
		return v
	}
	return r.qualityCapOvercommit
}

// effectiveMaxConcurrencyForModelLocked returns the per-provider admission
// concurrency cap for model from an explicit provider-level static rate
// (resolvedDecodeTPS). Kept for callers/tests that already resolved the rate;
// production admission paths use effectiveMaxConcurrencyForModelResolvedLocked
// so the cap consumes the per-model solo rate. Caller holds r.mu and p.mu.
func (r *Registry) effectiveMaxConcurrencyForModelLocked(p *Provider, model string, staticDecodeTPS float64) int {
	return r.effectiveMaxConcurrencyForModelRateLocked(p, model, soloModelTPS{tps: staticDecodeTPS})
}

// effectiveMaxConcurrencyForModelResolvedLocked is the per-model admission cap
// with the static solo rate resolved internally (resolvedSoloModelTPSLocked).
// This is what fixes the postmortem layer-6 failure: a mixed box benchmarked
// on gpt-oss (58–93 tok/s) no longer lends gemma its provider-level rate — the
// gemma cap is computed from gemma's own solo median (10–18 tok/s → cap 1–2).
// Caller holds r.mu and p.mu.
func (r *Registry) effectiveMaxConcurrencyForModelResolvedLocked(p *Provider, model string) int {
	return r.effectiveMaxConcurrencyForModelRateLocked(p, model, r.resolvedSoloModelTPSLocked(p, model))
}

// effectiveMaxConcurrencyForModelRateLocked returns the per-provider admission
// concurrency cap for model: the MINIMUM of the legacy cap
// (p.maxConcurrencyForModelLocked — a provider-reported per-slot MaxConcurrency
// if set, else the flat fallback) and quality_concurrency × overcommit. Taking
// the min means a provider that self-reports a TIGHTER cap still binds (it knows
// its backend best), while a provider that reports a looser cap — or none — is
// still held to the quality bar, so neither path can over-admit. rate must be a
// single-stream (static) decode rate for the model, not the observed-under-load
// value (which collapses under the overload this cap exists to prevent).
// Caller holds r.mu and p.mu.
func (r *Registry) effectiveMaxConcurrencyForModelRateLocked(p *Provider, model string, rate soloModelTPS) int {
	base := p.maxConcurrencyForModelLocked(model)
	if !r.qualityCapEnabled {
		return base
	}
	// The cap needs a trustworthy single-stream rate. p.DecodeTPS is the
	// provider-reported registration benchmark; without it, resolvedDecodeTPS falls
	// back to sqrt(memory_bandwidth) — a coarse, MODEL-AGNOSTIC hardware proxy that
	// under-estimates fast models (a ~57 tok/s gpt-oss reads as ~28), so hard-capping
	// a fast non-dedicated model from it could shed healthy traffic. Only cap from
	// the bandwidth fallback for DEDICATED models, which are known-slow and urgently
	// need it; a non-dedicated model without a real benchmark keeps the legacy flat
	// cap until its provider reports decode_tps. A PER-MODEL rate (solo median or
	// seed — rate.perModel) is model-specific by construction, so the guard does
	// not apply to it: those models are capped even without a registration
	// benchmark.
	if p.DecodeTPS <= 0 && !rate.perModel {
		if _, dedicated := r.dedicatedPatternForLocked(model); !dedicated {
			return base
		}
	}
	qc := qualityConcurrency(rate.tps, r.qualityCapFloorTPS, effectiveTPSLoadFactor, base, r.qualityCapFallback)
	capped := int(math.Ceil(float64(qc) * r.qualityCapOvercommitForModelLocked(model)))
	if capped < 1 {
		capped = 1
	}
	if capped < base {
		return capped
	}
	return base
}

// hasConcurrencyHeadroomForModelCapResolvedLocked mirrors
// Provider.hasConcurrencyHeadroomForModelLocked but applies the registry's
// quality-concurrency cap to the per-model limit, with the static single-stream
// decode rate resolved internally — per-model (solo median / seed) when
// available, else the provider-level rate. It is the single production entry
// point: the routing snapshot, the queue-drain preflight, the final admit
// re-check, the warm-pool saturation gate, and the public capacity feeds
// (ModelCapacitySnapshot) all consume it, so /v1/models[/capacity] report the
// SAME headroom the routing path enforces — otherwise a capped box is
// advertised as routable and upstream routers keep sending requests it 429s.
// Caller holds r.mu and p.mu.
func (r *Registry) hasConcurrencyHeadroomForModelCapResolvedLocked(p *Provider, model string) bool {
	return p.pendingLoadForModelLocked(model) < r.effectiveMaxConcurrencyForModelResolvedLocked(p, model) &&
		p.pendingCount() < p.maxConcurrency()
}

package registry

import "math"

// Quality-concurrency admission cap.
//
// The legacy per-provider concurrency cap is a flat 24 (maxConcurrency, for
// token-budget providers) — a hard-coded approximation of "how many concurrent
// decodes a backend can run before per-request TPS collapses". That single
// number is wrong for slow models: a 26B model that decodes ~23 tok/s solo
// drops below the 15 tok/s quality floor at a batch of 2, yet the flat cap let
// it accept up to 24 concurrent, collapsing every stream to a few tok/s and
// triggering cancellations.
//
// This computes the ceiling per provider+model from the model's batch-
// degradation curve instead — the same rate(B) = solo/(1+k·B) model the
// warm-pool target math uses (qualityConcurrency in warm_pool_target.go) — so
// admission and capacity planning cannot drift. Slow models get a tight cap;
// fast / over-provisioned models keep the flat fallback (their quality batch is
// already at or above it). The cap is computed from the provider's STATIC
// single-stream decode rate (resolvedDecodeTPS), NEVER the observed-under-load
// EWMA: the observed rate collapses under the very overload this cap exists to
// prevent, which would force the cap to 1 — a feedback loop.

// SetQualityConcurrencyCap configures the per-provider quality-concurrency
// admission cap. enabled=false leaves the legacy flat cap unchanged. overcommit
// multiplies the strict (floor-preserving) quality batch; <=0 falls back to 1.0.
// floorTPS and fallback mirror the warm-pool DecodeFloorTPS and
// FallbackQualityConcurrency so admission uses the same quality math as the
// warm-pool target. Called once at startup before the coordinator serves.
func (r *Registry) SetQualityConcurrencyCap(enabled bool, overcommit, floorTPS float64, fallback int) {
	if overcommit <= 0 {
		overcommit = 1.0
	}
	if fallback < 1 {
		fallback = 1
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.qualityCapEnabled = enabled
	r.qualityCapOvercommit = overcommit
	r.qualityCapFloorTPS = floorTPS
	r.qualityCapFallback = fallback
}

// effectiveMaxConcurrencyForModelLocked returns the per-provider admission
// concurrency cap for model: the MINIMUM of the legacy cap
// (p.maxConcurrencyForModelLocked — a provider-reported per-slot MaxConcurrency
// if set, else the flat fallback) and quality_concurrency × overcommit. Taking
// the min means a provider that self-reports a TIGHTER cap still binds (it knows
// its backend best), while a provider that reports a looser cap — or none — is
// still held to the quality bar, so neither path can over-admit. staticDecodeTPS
// must be the provider's single-stream (static) decode rate for the model
// (resolvedDecodeTPS), not the observed-under-load value (which collapses under
// the overload this cap exists to prevent). Caller holds r.mu and p.mu.
func (r *Registry) effectiveMaxConcurrencyForModelLocked(p *Provider, model string, staticDecodeTPS float64) int {
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
	// cap until its provider reports decode_tps.
	if p.DecodeTPS <= 0 {
		if _, dedicated := r.dedicatedPatternForLocked(model); !dedicated {
			return base
		}
	}
	qc := qualityConcurrency(staticDecodeTPS, r.qualityCapFloorTPS, effectiveTPSLoadFactor, base, r.qualityCapFallback)
	capped := int(math.Ceil(float64(qc) * r.qualityCapOvercommit))
	if capped < 1 {
		capped = 1
	}
	if capped < base {
		return capped
	}
	return base
}

// hasConcurrencyHeadroomForModelCapLocked mirrors
// Provider.hasConcurrencyHeadroomForModelLocked but applies the registry's
// quality-concurrency cap to the per-model limit. staticDecodeTPS is the
// provider's single-stream decode rate for the model. Caller holds r.mu and
// p.mu.
func (r *Registry) hasConcurrencyHeadroomForModelCapLocked(p *Provider, model string, staticDecodeTPS float64) bool {
	return p.pendingLoadForModelLocked(model) < r.effectiveMaxConcurrencyForModelLocked(p, model, staticDecodeTPS) &&
		p.pendingCount() < p.maxConcurrency()
}

// hasConcurrencyHeadroomForModelCapResolvedLocked is hasConcurrencyHeadroomForModelCapLocked
// with the provider's static single-stream decode rate resolved internally. Used
// by the public capacity feeds (ModelCapacitySnapshot) so /v1/models[/capacity]
// report the SAME headroom the routing path enforces — otherwise a capped box is
// advertised as routable and upstream routers keep sending requests it 429s.
// Caller holds r.mu and p.mu.
func (r *Registry) hasConcurrencyHeadroomForModelCapResolvedLocked(p *Provider, model string) bool {
	return r.hasConcurrencyHeadroomForModelCapLocked(p, model, resolvedDecodeTPS(p))
}

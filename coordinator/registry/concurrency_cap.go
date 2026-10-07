package registry

import (
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
)

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
//
// Raising a backend's own concurrency ceiling therefore buys NOTHING on its
// own. The provider-reported number is only the `base` operand of the MIN
// below; the resolved per-model SOLO RATE decides. Inverting the cap math, a
// provider is granted its full reported N only above
//
//	q    = floor((N-1)/overcommit) + 1     # smallest quality batch whose
//	                                       # ceil(q·overcommit) still reaches N
//	solo >= floor · (1 + k·q)              # N=8, floor 15, overcommit 1.2:
//	                                       #   39.3 tok/s at k=0.27
//	                                       #   50.1 tok/s at k=0.39
//
// and a model whose resolved rate sits under that gets the quality batch, not
// the bump. The rate is what needs fixing when a bump does not land — usually
// by seeding it (modelSoloTPSSeedEnv), because solo sampling is gated on a
// fully uncontended box (soloSampleEligible) and a model that is BUSY at the
// new concurrency never produces another sample. See
// TestQualityCapReachesProviderReportedConcurrency for the pinned relationship.

// defaultQualityCapOvercommit is the effective overcommit when the operator has
// not set EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT. The legacy 2.0 diluted
// per-request decode to roughly HALF the quality floor at full admission
// (rate(cap) → floor/overcommit under rate(B) = solo/(1+k·B)): production
// measured gemma-4-26b at p50 8 tok/s against the 15 tok/s floor, with 81% of
// successful requests below it. 1.2 bounds the dilution at ~floor/1.2 — the
// floor holds within the overcommit allowance instead of collapsing to half.
const defaultQualityCapOvercommit = quality.DefaultOvercommit

// qualityCapOvercommitByModelEnv is the per-model overcommit override map,
// e.g. EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL=
// "gemma-4-26b-qat-4bit=1.0,gpt-oss-20b=1.5" (same model=value CSV shape as
// EIGENINFERENCE_WARM_POOL_MIN_WARM). Keys are concrete resolved build ids,
// matched case-insensitively; values must be > 0. Models without an entry use
// the global overcommit.
const qualityCapOvercommitByModelEnv = env.EnvPrefix + "_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL"

// Per-model solo-TPS source for the quality cap (the postmortem layer-6 root
// fix — see resolvedSoloModelTPSLocked):
//
//   - qualityCapPerModelTPSEnv is the kill switch (bool, default TRUE). false
//     restores the provider-level resolvedDecodeTPS(p) rate at every quality-cap
//     site exactly.
//   - qualityCapSoloMinSamplesEnv is the minimum solo sample count (per chip,
//     or pooled across chips) before a solo median is trusted (int, default 5).
//   - modelSoloTPSSeedEnv is the cold-start seed, a "model=tok/s" CSV keyed by
//     concrete resolved build id (matched case-insensitively), with an
//     OPTIONAL "@chip-class" qualifier on the key, e.g.
//     "gemma-4-26b-qat-4bit=14,gemma-4-26b-qat-4bit@M4|Max=70". The TPS
//     registry is in-memory and restart-wiped, so the seed is the answer
//     until gated solo samples accumulate (e.g. while a model warms behind a
//     shed). See soloTPSSeedForClass for the resolution order and for why an
//     unqualified entry is clamped to the slowest class the operator named.
const (
	qualityCapPerModelTPSEnv    = env.EnvPrefix + "_QUALITY_CAP_PER_MODEL_TPS"
	qualityCapSoloMinSamplesEnv = env.EnvPrefix + "_QUALITY_CAP_SOLO_MIN_SAMPLES"
	modelSoloTPSSeedEnv         = env.EnvPrefix + "_MODEL_SOLO_TPS_SEED"
)

// defaultQualityCapSoloMinSamples is the solo-median trust floor when
// EIGENINFERENCE_QUALITY_CAP_SOLO_MIN_SAMPLES is unset.
const defaultQualityCapSoloMinSamples = quality.DefaultMinSamples

// SetQualityConcurrencyCap configures the per-provider quality-concurrency
// admission cap. enabled=false leaves the legacy flat cap unchanged. floorTPS
// and fallback mirror the warm-pool DecodeFloorTPS and
// FallbackQualityConcurrency so admission uses the same quality math as the
// warm-pool target. Called once at startup before the coordinator serves.
//
// The global overcommit multiplies the strict (floor-preserving) quality batch.
// The passed value is honored only when the operator explicitly set
// EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT: config.ReadConfig still parses
// that variable with the legacy 2.0 fallback, so when it is UNSET the caller is
// handing us that stale fallback and the real default —
// defaultQualityCapOvercommit — must apply instead. Per-model overrides
// (qualityCapOvercommitByModelEnv) are re-read from the environment here so the
// whole overcommit policy is resolved in one place.
func (r *Registry) SetQualityConcurrencyCap(enabled bool, overcommit, floorTPS float64, fallback int) {
	if v, explicit := os.LookupEnv(env.EnvPrefix + "_QUALITY_CONCURRENCY_OVERCOMMIT"); !explicit || strings.TrimSpace(v) == "" {
		overcommit = defaultQualityCapOvercommit
	}
	if overcommit <= 0 {
		overcommit = 1.0
	}
	if fallback < 1 {
		fallback = 1
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.qualityPolicy == nil {
		r.qualityPolicy = &quality.Policy{}
	}
	r.qualityPolicy.Configure(quality.Config{
		Enabled: enabled, Overcommit: overcommit, FloorTPS: floorTPS, Fallback: fallback,
		PerModelTPS: env.EnvBool(qualityCapPerModelTPSEnv, true),
		MinSamples:  env.EnvInt(qualityCapSoloMinSamplesEnv, defaultQualityCapSoloMinSamples),
		SoloSeed:    os.Getenv(modelSoloTPSSeedEnv), ModelOvercommit: os.Getenv(qualityCapOvercommitByModelEnv),
	})
	r.qualityCapEnabled = enabled
	r.qualityCapOvercommit = overcommit
	r.qualityCapFloorTPS = floorTPS
	r.qualityCapFallback = fallback
}

// QualityCapOvercommit returns the resolved global overcommit multiplier —
// the value admission actually uses, which can differ from the config struct's
// legacy fallback (see SetQualityConcurrencyCap).
func (r *Registry) QualityCapOvercommit() float64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.qualityCapOvercommit
}

func (r *Registry) qualityPolicyLocked() *quality.Policy {
	if r.qualityPolicy != nil {
		return r.qualityPolicy
	}
	return &quality.Policy{}
}

// soloModelTPS is a static single-stream decode rate for a (provider, model)
// pair plus its provenance. perModel is true when the rate came from a
// model-specific source — a gated solo median or the seed env — which is
// trustworthy for capping even when the provider never reported a registration
// benchmark; false means the rate is the provider-level resolvedDecodeTPS
// chain (registration benchmark, or the model-agnostic sqrt-bandwidth proxy
// that only dedicated models may be capped from).
type soloModelTPS struct {
	tps      float64
	perModel bool
}

// resolvedSoloModelTPSLocked resolves the static solo decode rate the quality
// cap should use for (p, model). Fallback chain, most- to least-specific:
//
//  1. per-(model, chip CLASS) solo median — gated samples only (solo_tps.go),
//     keyed by chipClassKey (family+tier) so a fast tier never lends its rate
//     to a slow one — once it has ≥ qualityCapSoloMinSamples samples;
//  2. the MIN of the per-class solo medians across chip classes (conservative
//     cross-class transfer, SoloMedianAllChips), same total-sample floor, and
//     only when that minimum is actually BOUNDED for this provider — see
//     "when cross-class transfer is admissible" below;
//  3. the same-class solo median with FEWER than qualityCapSoloMinSamples
//     samples (but at least one), then the bounded cross-class median under
//     the same relaxation. These are under-sampled but they are still
//     MEASURED and still solo-gated, and the alternative below them is a
//     model-AGNOSTIC hardware proxy: preferring sqrt(memory_bandwidth) over
//     the provider's own measurement of this exact model is strictly worse
//     information. See the note on convergence below;
//  4. the modelSoloTPSSeedEnv seed for this provider's chip class when there
//     is no measured rate at all — the class-qualified entry, else the
//     fleet-wide entry clamped to the slowest class the operator named
//     (soloTPSSeedForClass). The TPS registry is in-memory and restart-wiped,
//     and a provider that has completed no request reports no rate (see
//     below);
//  5. the provider-level resolvedDecodeTPS(p) — exactly the pre-per-model
//     behavior, including its sqrt-bandwidth fallback semantics.
//
// When cross-class transfer is admissible. Steps (2) and (3) hand a provider a
// rate its own chip class did not produce, so the transferred value needs an
// upper bound or a fast class silently sets a slow class's cap — the exact
// over-admission this whole cap exists to prevent. Three things can supply
// that bound, and at least one MUST hold:
//
//   - a modelSoloTPSSeedEnv seed applies to THIS provider's chip class
//     (soloTPSSeedForClass) — the configured cold-start estimate clamps the
//     transfer from above;
//   - the provider's own class contributed at least one sample, so the min of
//     per-class medians cannot exceed what its own class demonstrated;
//   - at least two classes contributed. This one is WEAKER than it looks and
//     is not a bound on the destination: the min over {M4 Max, M3 Max} is
//     still a Max-tier rate, and handing it to an unsampled M1 Pro over-states
//     that box by 4x. It is admitted anyway because it is a partial brake —
//     refusing it drops to (4)/(5), and resolvedDecodeTPS is usually FASTER
//     than the cross-class min (a mixed box benchmarked on gpt-oss reads 93
//     tok/s), so refusing would LOOSEN the cap in most fleet shapes rather
//     than tighten it. Measured: over 600 shapes where this arm is the sole
//     admission reason, refusing loosens 338, tightens 81, no change in 181.
//     The destination-bound input to quality.Policy supplies the missing bound.
//
// With none of them, the "min of per-class medians" is a single fast class's
// rate being applied to an unsampled slower one — one M4 Max sample setting an
// unseeded M1 Pro's rate. That is refused: the resolver drops to (4)/(5),
// which is the pre-per-model behaviour and errs toward serving rather than
// toward capping a box from evidence about different hardware.
//
// Reachability note for whoever edits crossClassBounded next: the third arm
// cannot fire on the current production fleet. The shipped
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED carries UNQUALIFIED entries for both
// served models ("gemma-4-26b-qat-4bit=14,gpt-oss-20b=30"), and an unqualified
// entry resolves through the policy's fleet seed index for EVERY chip class, so
// hasSeed is true fleet-wide and the first arm always short-circuits it. The
// arm is live only for a model added without an unqualified seed entry.
// TestSoloSeedUnqualifiedEntryMakesEveryClassSeeded pins that.
//
// What a provider reports BEFORE its first completion: nothing. The bridge's
// EWMA (EngineV2Bridge.observedDecodeTpsEwma) is 0 until updateDecodeTpsEwma
// runs on a terminal event, `observed_decode_tps` is `omitempty`, and the
// heartbeat ingest only calls RecordSolo when the reported value is > 0
// (heartbeat.go). So a fresh provider contributes NO solo sample, reaches (4)
// or (5), and is never capped at 1 by its own silence. Steps (3) can only
// engage once a real decode has been measured.
//
// Under-sampled samples converge from BELOW, which is the safe direction. The
// bridge EWMA (alpha = 0.3) blends prior batched decodes, so the first sample
// taken as the box drops to a single running request UNDER-states the true
// solo rate; it can never materially over-state it (solo is the fastest case,
// and the ingest path already clamps to maxDecodeTPS). An under-stated rate
// yields a TIGHTER cap, never a permissive one.
//
// The rate is deliberately STATIC (never an under-load EWMA): an observed rate
// collapses under the very overload the cap exists to prevent, which would
// drive the cap to 1 in a feedback loop. Solo medians preserve that property
// because ingest is gated on a fully uncontended box.
//
// The qualityCapPerModelTPSEnv kill switch (false) short-circuits to (5),
// restoring resolvedDecodeTPS(p) at every wired site exactly. Caller holds
// r.mu and p.mu.
func (r *Registry) resolvedSoloModelTPSLocked(p *Provider, model string) soloModelTPS {
	policy := r.qualityPolicyLocked()
	var evidence quality.SoloEvidence
	chipClass := ""
	if policy.PerModelEnabled() {
		chipClass = chipClassKey(p.Hardware)
		evidence.ClassTPS, evidence.ClassSamples = r.tpsRegistry.SoloMedian(model, chipClass)
		evidence.MinimumTPS, evidence.TotalSamples, evidence.Classes = r.tpsRegistry.SoloMedianAllChips(model)
	}
	rate := policy.Resolve(evidence, model, chipClass,
		quality.DecodeFallback(p.DecodeTPS, p.Hardware), p.DecodeTPS > 0 || p.Hardware.MemoryBandwidthGBs > 0)
	return soloModelTPS{tps: rate.TPS, perModel: rate.PerModel}
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
	_, dedicated := r.dedicatedPatternForLocked(model)
	return r.qualityPolicyLocked().Cap(model, base, quality.Rate{TPS: rate.tps, PerModel: rate.perModel},
		p.DecodeTPS > 0, dedicated, effectiveTPSLoadFactor, (*performance.Profile)(qualifiedPerformanceProfileLocked(p, model)))
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
	_, headroom := r.concurrencyHeadroomReportLocked(p, model)
	return headroom
}

func (r *Registry) hasPendingConcurrencyHeadroomLocked(p *Provider, model string) bool {
	return p.pendingLoadForModelLocked(model) < r.effectiveMaxConcurrencyForModelResolvedLocked(p, model) &&
		p.pendingCount() < p.maxConcurrency()
}

// concurrencyHeadroomReportLocked leaves saturated providers on the cheap
// count gates; a successful preflight lends its validation to deadline work.
func (r *Registry) concurrencyHeadroomReportLocked(p *Provider, model string) (capacityvalue.ServiceReport, bool) {
	if !r.hasPendingConcurrencyHeadroomLocked(p, model) {
		return capacityvalue.ServiceReport{}, false
	}
	report := capacityvalue.NewServiceReport(p.BackendCapacity)
	return report, p.serviceReservationsLocked().hasHeadroomWithReport(model, report)
}

// The routing snapshot has already validated this report for deadline work.
// The same provider lock protects it through the admission check.
func (r *Registry) hasConcurrencyHeadroomWithReportLocked(p *Provider, model string, report capacityvalue.ServiceReport) bool {
	return r.hasPendingConcurrencyHeadroomLocked(p, model) && p.serviceReservationsLocked().hasHeadroomWithReport(model, report)
}

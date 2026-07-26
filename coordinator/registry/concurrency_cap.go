package registry

import (
	"math"
	"os"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
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
const defaultQualityCapOvercommit = 1.2

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
const defaultQualityCapSoloMinSamples = 5

// qualityCapOvercommitByModel holds the parsed per-model overrides. Like the
// package's other startup-configured routing knobs (prefillToDecodeRatio,
// ttftOccupancyAlpha), it is written once by SetQualityConcurrencyCap before
// the coordinator serves and only read on routing paths thereafter.
var qualityCapOvercommitByModel map[string]float64

// qualityCapPerModelTPS / qualityCapSoloMinSamples / modelSoloTPSSeed /
// modelSoloTPSSeedFleet are the parsed per-model solo-TPS knobs. Same
// lifecycle as qualityCapOvercommitByModel: written once by
// SetQualityConcurrencyCap before serving, read-only on routing paths.
//
// modelSoloTPSSeed holds EVERY parsed seed entry, class-qualified
// ("gemma-4-26b-qat-4bit@m4|max") and unqualified ("gemma-4-26b-qat-4bit")
// alike. modelSoloTPSSeedFleet holds only the unqualified ones, each already
// clamped by soloSeedFleetFallbacks, so the routing-path lookup is two map
// reads and no iteration.
var (
	qualityCapPerModelTPS    = true
	qualityCapSoloMinSamples = defaultQualityCapSoloMinSamples
	modelSoloTPSSeed         map[string]float64
	modelSoloTPSSeedFleet    map[string]float64
)

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
	qualityCapOvercommitByModel = parseModelFloatMap(os.Getenv(qualityCapOvercommitByModelEnv))
	qualityCapPerModelTPS = env.EnvBool(qualityCapPerModelTPSEnv, true)
	qualityCapSoloMinSamples = env.EnvInt(qualityCapSoloMinSamplesEnv, defaultQualityCapSoloMinSamples)
	if qualityCapSoloMinSamples < 1 {
		qualityCapSoloMinSamples = 1
	}
	modelSoloTPSSeed = parseModelFloatMap(os.Getenv(modelSoloTPSSeedEnv))
	modelSoloTPSSeedFleet = soloSeedFleetFallbacks(modelSoloTPSSeed)
	r.mu.Lock()
	defer r.mu.Unlock()
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

// parseModelFloatMap parses the "model=value,..." CSV form (mirroring
// envModelIntMap for EIGENINFERENCE_WARM_POOL_MIN_WARM, with float values).
// Keys are lowercased so lookups on resolved build ids match
// case-insensitively. Malformed, non-positive, and non-finite values are all
// skipped — strconv.ParseFloat happily yields NaN and ±Inf ("m=NaN" passes a
// naive v <= 0 filter because NaN comparisons are always false), and either
// one flows into int(math.Ceil(...)) / qualityConcurrency as an
// implementation-defined integer, silently strangling the model to cap 1.
// An empty or all-invalid input yields nil (no entries). Shared by the
// per-model overcommit overrides (qualityCapOvercommitByModelEnv) and the
// solo-TPS seed (modelSoloTPSSeedEnv).
func parseModelFloatMap(raw string) map[string]float64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	out := make(map[string]float64)
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		model, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		model = strings.ToLower(strings.TrimSpace(model))
		if model == "" {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v <= 0 {
			continue
		}
		out[model] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// soloSeedClassSep separates the build id from an optional chip-CLASS
// qualifier inside a modelSoloTPSSeedEnv key:
// "gemma-4-26b-qat-4bit@M4|Max=70". The qualifier is a chipClassKey
// (solo_tps.go) — ChipFamily|ChipTier, or the raw ChipName when the family is
// absent — so the seed table keys exactly the way the solo-sample store does
// and an operator reads one class vocabulary, not two. "@" cannot collide
// with a build id (they are model-name/quantization slugs) and "," is already
// the entry separator, so the grammar stays inside parseModelFloatMap.
const soloSeedClassSep = "@"

// soloSeedFleetFallbacks extracts the UNQUALIFIED seed entries and clamps each
// to the slowest class-qualified seed declared for the same model.
//
// SAFETY INVARIANT — the same one SoloMedianAllChips enforces for MEASURED
// medians, applied to CONFIGURED ones: a chip class the operator did not name
// must never be credited with more than the slowest class they did name. A
// seed is a measurement of one class. The 70 tok/s gemma seed came off an M4
// Max (~99.5 tok/s solo paged); an M1 Pro that decodes gemma at 14 tok/s and
// inherits it is granted cap 8 and projects ~3.4 tok/s per request at batch
// 8, far under the 15 tok/s quality floor — the over-admission the whole
// quality cap exists to prevent, arriving through its own cold-start knob.
// Clamping makes an unrecognized class degrade toward UNDER-admission
// whatever order the operator writes the CSV in.
//
// Precomputed at startup so the routing path never iterates the seed table.
func soloSeedFleetFallbacks(seed map[string]float64) map[string]float64 {
	if len(seed) == 0 {
		return nil
	}
	slowestClass := make(map[string]float64)
	for key, v := range seed {
		model, _, qualified := strings.Cut(key, soloSeedClassSep)
		if !qualified {
			continue
		}
		if cur, ok := slowestClass[model]; !ok || v < cur {
			slowestClass[model] = v
		}
	}
	out := make(map[string]float64, len(seed))
	for key, v := range seed {
		if strings.Contains(key, soloSeedClassSep) {
			continue
		}
		if floor, ok := slowestClass[key]; ok && floor < v {
			v = floor
		}
		out[key] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// soloTPSSeedForClass resolves the cold-start seed for (model, chip class):
//
//  1. the class-qualified entry for the provider's OWN chip class, when the
//     operator declared one — the only place a class-specific measurement is
//     allowed to apply;
//  2. the unqualified fleet-wide entry, already clamped to the slowest class
//     the operator named (soloSeedFleetFallbacks);
//  3. no seed at all, which drops the resolver to resolvedDecodeTPS(p) —
//     exactly the pre-seed behaviour, and the conservative outcome when an
//     operator seeds only the class they measured.
//
// An unrecognized chip reaches the coordinator as ChipFamily "Unknown" /
// ChipTier "Unknown" (HardwareDetector.parseChipIdentity), i.e. class
// "Unknown|Unknown", so it matches no class-qualified entry and takes (2) or
// (3). Both are floors, never the fast class's rate.
func soloTPSSeedForClass(model, chipClass string) (float64, bool) {
	m := strings.ToLower(model)
	if chipClass != "" {
		if v, ok := modelSoloTPSSeed[m+soloSeedClassSep+strings.ToLower(chipClass)]; ok {
			return v, true
		}
	}
	v, ok := modelSoloTPSSeedFleet[m]
	return v, ok
}

// qualityCapOvercommitForModelLocked resolves the overcommit for a model: the
// per-model override when one exists for the resolved build id, else the global
// value. Caller holds r.mu.
func (r *Registry) qualityCapOvercommitForModelLocked(model string) float64 {
	if v, ok := qualityCapOvercommitByModel[strings.ToLower(model)]; ok {
		return v
	}
	return r.qualityCapOvercommit
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
// over-admission this whole cap exists to prevent. Exactly three things can
// supply that bound, and at least one MUST hold:
//
//   - a modelSoloTPSSeedEnv seed applies to THIS provider's chip class
//     (soloTPSSeedForClass) — the configured cold-start estimate clamps the
//     transfer from above;
//   - the provider's own class contributed at least one sample, so the min of
//     per-class medians cannot exceed what its own class demonstrated;
//   - at least two classes contributed, so the minimum is a genuine
//     cross-class minimum rather than one class's median wearing that name.
//
// With none of them, the "min of per-class medians" is a single fast class's
// rate being applied to an unsampled slower one — one M4 Max sample setting an
// unseeded M1 Pro's rate. That is refused: the resolver drops to (4)/(5),
// which is the pre-per-model behaviour and errs toward serving rather than
// toward capping a box from evidence about different hardware.
//
// What a provider reports BEFORE its first completion: nothing. The bridge's
// EWMA (EngineV2Bridge.observedDecodeTpsEwma) is 0 until updateDecodeTpsEwma
// runs on a terminal event, `observed_decode_tps` is `omitempty`, and the
// heartbeat ingest only calls RecordSolo when the reported value is > 0
// (registry.go). So a fresh provider contributes NO solo sample, reaches (4)
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
// The qualityCapPerModelTPSEnv kill switch (false) short-circuits to (4),
// restoring resolvedDecodeTPS(p) at every wired site exactly. Caller holds
// r.mu and p.mu.
func (r *Registry) resolvedSoloModelTPSLocked(p *Provider, model string) soloModelTPS {
	if qualityCapPerModelTPS {
		chipClass := chipClassKey(p.Hardware)
		classTPS, classN := r.tpsRegistry.SoloMedian(model, chipClass)
		if classN >= qualityCapSoloMinSamples && classTPS > 0 {
			return soloModelTPS{tps: classTPS, perModel: true}
		}
		seed, hasSeed := soloTPSSeedForClass(model, chipClass)
		allTPS, allN, allClasses := r.tpsRegistry.SoloMedianAllChips(model)
		// Seed-clamp the cross-class transfer: observations from faster classes
		// cannot widen an unsampled slower class's cap above its configured
		// cold-start estimate. Applies at both sample floors.
		if allTPS > 0 && hasSeed && seed < allTPS {
			allTPS = seed
		}
		// ...and refuse it outright when nothing bounds it (see above). An
		// unbounded transfer is not conservative just because the function it
		// came from is named for a minimum.
		crossClassBounded := hasSeed || classN > 0 || allClasses > 1
		if crossClassBounded && allN >= qualityCapSoloMinSamples && allTPS > 0 {
			return soloModelTPS{tps: allTPS, perModel: true}
		}
		// Measured but under-sampled. Ranked below both trusted medians and
		// above the seed: a real solo-gated measurement of THIS model beats a
		// fleet-wide configured guess, and both beat the model-agnostic
		// sqrt-bandwidth proxy that pins a fast model to cap 1-2.
		if classN > 0 && classTPS > 0 {
			return soloModelTPS{tps: classTPS, perModel: true}
		}
		if crossClassBounded && allN > 0 && allTPS > 0 {
			return soloModelTPS{tps: allTPS, perModel: true}
		}
		if hasSeed {
			return soloModelTPS{tps: seed, perModel: true}
		}
	}
	return soloModelTPS{tps: resolvedDecodeTPS(p), perModel: false}
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

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
//     concrete resolved build id (matched case-insensitively), e.g.
//     "gemma-4-26b-qat-4bit=14,gpt-oss-20b=30". The TPS registry is in-memory
//     and restart-wiped, so the seed is the answer until gated solo samples
//     accumulate (e.g. while a model warms behind a shed).
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

// qualityCapPerModelTPS / qualityCapSoloMinSamples / modelSoloTPSSeed are the
// parsed per-model solo-TPS knobs. Same lifecycle as
// qualityCapOvercommitByModel: written once by SetQualityConcurrencyCap before
// serving, read-only on routing paths.
var (
	qualityCapPerModelTPS    = true
	qualityCapSoloMinSamples = defaultQualityCapSoloMinSamples
	modelSoloTPSSeed         map[string]float64
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
//     cross-class transfer, SoloMedianAllChips), same total-sample floor. When
//     a modelSoloTPSSeedEnv seed exists, it is an upper bound on that transfer:
//     observations from faster classes cannot widen an unsampled slower class's
//     cap above its configured cold-start estimate;
//  3. the modelSoloTPSSeedEnv seed when there is no trusted cross-class rate
//     (the TPS registry is in-memory and restart-wiped);
//  4. the provider-level resolvedDecodeTPS(p) — exactly the pre-per-model
//     behavior, including its sqrt-bandwidth fallback semantics.
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
		if tps, n := r.tpsRegistry.SoloMedian(model, chipClassKey(p.Hardware)); n >= qualityCapSoloMinSamples && tps > 0 {
			return soloModelTPS{tps: tps, perModel: true}
		}
		seed, hasSeed := modelSoloTPSSeed[strings.ToLower(model)]
		if tps, n := r.tpsRegistry.SoloMedianAllChips(model); n >= qualityCapSoloMinSamples && tps > 0 {
			if hasSeed && seed < tps {
				tps = seed
			}
			return soloModelTPS{tps: tps, perModel: true}
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
// decode rate resolved internally. It is the single production entry point for
// routing, queue preflight, final admission, warm-pool saturation, and public
// capacity. The candidate rate is resolved once and shared with the box-wide
// combined cap so the two gates cannot disagree on rate provenance.
// Caller holds r.mu and p.mu.
func (r *Registry) hasConcurrencyHeadroomForModelCapResolvedLocked(p *Provider, model string) bool {
	rate := r.resolvedSoloModelTPSLocked(p, model)
	return p.pendingLoadForModelLocked(model) < r.effectiveMaxConcurrencyForModelRateLocked(p, model, rate) &&
		p.pendingCount() < p.maxConcurrency() &&
		r.combinedAdmissionHeadroomLocked(p, model, rate)
}

// SetCombinedAdmissionCap toggles the box-wide combined admission budget (see
// combinedAdmissionHeadroomLocked). Called once at startup, from
// EIGENINFERENCE_COMBINED_ADMISSION_CAP; default false leaves per-model
// admission byte-identical to the independent per-model caps.
func (r *Registry) SetCombinedAdmissionCap(enabled bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.combinedAdmissionCap = enabled
}

// combinedAdmissionEpsilon absorbs float rounding in the Σ(load/qc) budget so a
// box exactly AT its overcommit budget (e.g. 1.0 + 1/5 vs overcommit 1.2) is not
// rejected on the last binary digit.
const combinedAdmissionEpsilon = 1e-9

// combinedSlotLoad is one backend slot's contribution to the combined admission
// budget: its current load and the quality concurrency of its model on this
// provider. qc <= 0 marks the slot's quality concurrency unresolvable — the slot
// is skipped (fails open per-slot) rather than guessed.
type combinedSlotLoad struct {
	load int
	qc   int
}

// combinedAdmissionAdmits is the pure core of the combined (box-wide) admission
// cap:
//
//	Σ_slots(load_s / qc_s) + 1/qc_candidate <= overcommit
//
// Each slot's in-flight load is normalized by that model's quality concurrency,
// so the sum is the fraction of the box's quality-bounded capacity already
// committed, on a scale where 1.0 = "every resident model at its own quality
// batch". Admitting one more request of the candidate model costs 1/qc_candidate.
// The bound is the candidate model's resolved overcommit — the same allowance the
// per-model cap grants. An unresolvable candidate qc (<= 0) fails open, matching
// the per-model cap's trust rules, and a box with ZERO combined load always
// admits — the same at-least-one floor the per-model cap applies (capped < 1 →
// 1), so a sub-1/qc overcommit can never starve an idle box.
func combinedAdmissionAdmits(slots []combinedSlotLoad, candidateQC int, overcommit float64) bool {
	if candidateQC <= 0 {
		return true
	}
	used := 0.0
	for _, s := range slots {
		if s.qc <= 0 || s.load <= 0 {
			continue
		}
		used += float64(s.load) / float64(s.qc)
	}
	if used == 0 {
		return true
	}
	return used+1.0/float64(candidateQC) <= overcommit+combinedAdmissionEpsilon
}

// combinedAdmissionHeadroomLocked applies the box-wide combined admission cap
// (combinedAdmissionAdmits) to a candidate (provider, model) pair. Per-model
// caps are checked independently, so a box saturated on model A still admits
// model B — each model sees only its own slot. This gate sums every resident
// slot's normalized load so cross-model saturation is visible at admission (the
// hard edge that lets the pool open before contention-aware scoring lands).
//
// Dormant unless BOTH EIGENINFERENCE_COMBINED_ADMISSION_CAP and the quality cap
// are enabled. Candidate and co-resident quality concurrency both use
// resolvedSoloModelTPSLocked, the same per-model solo median / seed / provider
// fallback chain as the independent cap. The trust rule also matches the
// independent cap: an unbenchmarked non-dedicated model with only the coarse
// provider fallback is unresolvable and fails open rather than being hard-capped.
//
// Per-slot load is the model-scoped max(coordinator-pending, backend
// running+waiting) — pendingLoadForModelLocked's semantics — computed inline
// because that helper's legacy fallback (no reported MaxConcurrency → TOTAL
// pending count) is per-model-safe but would double-count when summed across
// slots. Caller holds r.mu and p.mu.
func (r *Registry) combinedAdmissionHeadroomLocked(p *Provider, model string, candidate soloModelTPS) bool {
	if !r.combinedAdmissionCap || !r.qualityCapEnabled {
		return true
	}
	candidateQC := r.combinedQualityConcurrencyLocked(p, model, candidate)
	var slots []combinedSlotLoad
	if p.BackendCapacity != nil {
		slots = make([]combinedSlotLoad, 0, len(p.BackendCapacity.Slots))
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == "" {
				continue
			}
			load := p.pendingCountForModelLocked(slot.Model)
			if backendLoad := clampNonNegative(slot.NumRunning) + clampNonNegative(slot.NumWaiting); backendLoad > load {
				load = backendLoad
			}
			slotRate := r.resolvedSoloModelTPSLocked(p, slot.Model)
			if slot.Model == model {
				slotRate = candidate
			}
			qc := r.combinedQualityConcurrencyLocked(p, slot.Model, slotRate)
			slots = append(slots, combinedSlotLoad{load: load, qc: qc})
		}
	}
	return combinedAdmissionAdmits(slots, candidateQC, r.qualityCapOvercommitForModelLocked(model))
}

// combinedQualityConcurrencyLocked resolves the strict quality concurrency used
// by the combined budget while applying the same provenance trust rule as the
// independent per-model cap. Zero means unresolvable and is handled fail-open by
// combinedAdmissionAdmits. Caller holds r.mu and p.mu.
func (r *Registry) combinedQualityConcurrencyLocked(p *Provider, model string, rate soloModelTPS) int {
	if rate.tps <= 0 {
		return 0
	}
	if p.DecodeTPS <= 0 && !rate.perModel {
		if _, dedicated := r.dedicatedPatternForLocked(model); !dedicated {
			return 0
		}
	}
	return qualityConcurrency(rate.tps, r.qualityCapFloorTPS, effectiveTPSLoadFactor,
		p.maxConcurrencyForModelLocked(model), r.qualityCapFallback)
}

// clampNonNegative floors a heartbeat-reported count at 0 so a malformed slot
// cannot subtract from the combined load sum.
func clampNonNegative(v int) int {
	if v < 0 {
		return 0
	}
	return v
}

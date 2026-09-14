package registry

import (
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

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
// modelSoloTPSSeed holds EVERY parsed seed entry as the operator wrote it,
// class-qualified ("gemma-4-26b-qat-4bit@m4|max") and unqualified
// ("gemma-4-26b-qat-4bit") alike. It is the PARSE result, not a lookup table:
// routing never reads it.
//
// modelSoloTPSSeedByClass is the routing-path table, nested model → class →
// rate. Nested rather than flat-with-a-composite-key because the flat form
// forced soloTPSSeedForClass to BUILD "model@class" on every probe — and that
// probe runs once per candidate provider per request inside
// snapshotProviderIntoLockedEx, under both r.mu and p.mu, ~94 times on a full fleet.
// Two map reads allocate nothing; one string concatenation allocates every
// time.
//
// modelSoloTPSSeedFleet holds only the unqualified entries, each already
// clamped by soloSeedFleetFallbacks.
var (
	qualityCapPerModelTPS    = true
	qualityCapSoloMinSamples = defaultQualityCapSoloMinSamples
	modelSoloTPSSeed         map[string]float64
	modelSoloTPSSeedByClass  map[string]map[string]float64
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
	modelSoloTPSSeedByClass = soloSeedByClass(modelSoloTPSSeed)
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

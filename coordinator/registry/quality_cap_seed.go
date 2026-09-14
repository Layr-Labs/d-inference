package registry

import (
	"math"
	"strconv"
	"strings"
)

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

// soloSeedByClass pivots the flat parsed seed table into model → class → rate,
// so the routing-path lookup is two map reads instead of a concatenation.
// Unqualified entries are NOT folded in: they resolve through
// modelSoloTPSSeedFleet, which applies the slowest-class clamp below, and
// putting them here under a synthetic class key would let a provider match the
// unclamped value.
//
// Precomputed at startup, read-only thereafter, same lifecycle as everything
// else SetQualityConcurrencyCap writes.
func soloSeedByClass(seed map[string]float64) map[string]map[string]float64 {
	if len(seed) == 0 {
		return nil
	}
	out := make(map[string]map[string]float64)
	for key, v := range seed {
		model, class, qualified := strings.Cut(key, soloSeedClassSep)
		if !qualified {
			continue
		}
		byClass := out[model]
		if byClass == nil {
			byClass = make(map[string]float64, 1)
			out[model] = byClass
		}
		byClass[class] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

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
// HOT PATH: once per candidate provider per request, inside
// snapshotProviderIntoLockedEx under both r.mu and p.mu. Every lookup here is a map
// read against an already-lowered key; nothing is concatenated and nothing is
// allocated when the strings are already lower-case ASCII (strings.ToLower
// returns its argument unchanged in that case, which is the common one — the
// class key is built from a fixed vocabulary and most build ids are slugs).
func soloTPSSeedForClass(model, chipClass string) (float64, bool) {
	m := strings.ToLower(model)
	if chipClass != "" && modelSoloTPSSeedByClass != nil {
		if byClass := modelSoloTPSSeedByClass[m]; byClass != nil {
			if v, ok := byClass[strings.ToLower(chipClass)]; ok {
				return v, true
			}
		}
	}
	v, ok := modelSoloTPSSeedFleet[m]
	return v, ok
}

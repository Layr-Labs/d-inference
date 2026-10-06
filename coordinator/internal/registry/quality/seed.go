package quality

import (
	"math"
	"strconv"
	"strings"
)

// ParseModelFloatMap accepts finite positive CSV values and case-folded keys.
func ParseModelFloatMap(raw string) map[string]float64 {
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

// SeedByClass precomputes model/class lookup without composite-key allocation.
func SeedByClass(seed map[string]float64) map[string]map[string]float64 {
	if len(seed) == 0 {
		return nil
	}
	out := make(map[string]map[string]float64)
	for key, v := range seed {
		model, class, qualified := strings.Cut(key, SeedClassSeparator)
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

// SeedFleetFallbacks clamps unqualified entries to the slowest named class.
// An unnamed class can never outrank the slowest class the operator measured.
func SeedFleetFallbacks(seed map[string]float64) map[string]float64 {
	if len(seed) == 0 {
		return nil
	}
	slowestClass := make(map[string]float64)
	for key, v := range seed {
		model, _, qualified := strings.Cut(key, SeedClassSeparator)
		if !qualified {
			continue
		}
		if cur, ok := slowestClass[model]; !ok || v < cur {
			slowestClass[model] = v
		}
	}
	out := make(map[string]float64, len(seed))
	for key, v := range seed {
		if strings.Contains(key, SeedClassSeparator) {
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

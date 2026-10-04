package residency

import "strings"

// ModelFit is detached workload qualification, never live provider state.
type ModelFit struct {
	Rate           float64 // sustainable request equivalents/sec for this workload
	ServiceSeconds float64
	LoadSeconds    float64
	WeightsGiB     float64 // padded incoming transient
	Restricted     bool
	Measured       bool
	MeetsDeadline  bool
}

func ModelID(key string) string { model, _, _ := strings.Cut(key, "\x1f"); return model }

func QualifiedResident(fits map[string]ModelFit, model string) bool {
	for key, fit := range fits {
		if ModelID(key) == model && fit.MeetsDeadline && fit.Rate > 0 {
			return true
		}
	}
	return false
}

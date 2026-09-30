package registry

import "encoding/json"

// Decode only compiled, review-controlled data. Any bad record invalidates the
// entire catalog, preserving the legacy deadline predictor instead of partially
// activating evidence. No provider/operator file can populate this catalog.
func decodeDeadlineProfileCatalog(raw string) map[string]*deadlinePerformanceProfile {
	out := make(map[string]*deadlinePerformanceProfile)
	var profiles []*deadlinePerformanceProfile
	if err := json.Unmarshal([]byte(raw), &profiles); err != nil || profiles == nil {
		return out
	}
	for _, profile := range profiles {
		if !profile.valid() {
			return map[string]*deadlinePerformanceProfile{}
		}
		if _, duplicate := out[profile.ID]; duplicate {
			return map[string]*deadlinePerformanceProfile{}
		}
		out[profile.ID] = profile
	}
	return out
}

// Package firstcontent contains the reviewed, workload-bounded deadline model.
// It has no clocks, provider state, routing policy, or memory admission effects.
package firstcontent

import "math"

const Version = 1

// Calibration belongs to an exact deadline profile. Template identity is kept
// separately from its weight digest because changing a template changes work.
type Calibration struct {
	Version          int    `json:"version"`
	PromptContractID string `json:"prompt_contract_id"`
	Cells            []Cell `json:"cells"`
}

// Cell is an empirically validated envelope, never an interpolated hardware
// claim. Rates and error parameters are promoted together with their report.
// Active requests include the incoming request; other-model limits exclude it.
type Cell struct {
	PromptTokensMin              int      `json:"prompt_tokens_min"`
	PromptTokensMax              int      `json:"prompt_tokens_max"`
	ContextTokensMin             int      `json:"context_tokens_min"`
	ContextTokensMax             int      `json:"context_tokens_max"`
	CacheState                   string   `json:"cache_state"`
	Contention                   string   `json:"contention"`
	CompetitorProfileIDs         []string `json:"competitor_profile_ids"`
	MaxOtherModelRequests        int      `json:"max_other_model_requests"`
	MaxOtherModelServiceFraction float64  `json:"max_other_model_service_fraction"`
	PrefillTPS                   float64  `json:"prefill_tps"`
	DecodeTPS                    float64  `json:"decode_tps"`
	MaxPrefillWorkTokens         int      `json:"max_prefill_work_tokens"`
	MaxDecodeWorkTokens          int      `json:"max_decode_work_tokens"`
	MaxActiveRequests            int      `json:"max_active_requests"`
	ErrorRatio                   float64  `json:"error_ratio"`
	ErrorAdditiveMS              float64  `json:"error_additive_ms"`
	CalibrationSampleCount       int      `json:"calibration_sample_count"`
	ValidationSampleCount        int      `json:"validation_sample_count"`
	ValidationCoveredCount       int      `json:"validation_covered_count"`
	TailCoverage                 float64  `json:"tail_coverage"`
	ReportSHA256                 string   `json:"report_sha256"`
}

func (c *Calibration) Valid(contextLimit int) bool {
	if c == nil || c.Version != Version || !digest(c.PromptContractID) || len(c.Cells) == 0 || len(c.Cells) > 256 {
		return false
	}
	for _, cell := range c.Cells {
		if !cell.Valid(contextLimit) {
			return false
		}
	}
	return true
}

func (c Cell) Valid(contextLimit int) bool {
	if c.PromptTokensMin < 1 || c.PromptTokensMax < c.PromptTokensMin || c.PromptTokensMax > contextLimit ||
		c.ContextTokensMin < 1 || c.ContextTokensMax < c.ContextTokensMin || c.ContextTokensMax > contextLimit ||
		(c.CacheState != "cold" && c.CacheState != "reused") ||
		!positive(c.PrefillTPS) || c.PrefillTPS > 20000 || !positive(c.DecodeTPS) || c.DecodeTPS > 20000 ||
		c.MaxPrefillWorkTokens < 0 || c.MaxDecodeWorkTokens < 1 || c.MaxActiveRequests < 1 || c.MaxActiveRequests > 64 ||
		!positive(c.ErrorRatio) || c.ErrorRatio < 1 || !nonnegative(c.ErrorAdditiveMS) ||
		c.CalibrationSampleCount < 20 || c.ValidationSampleCount < 20 || c.ValidationCoveredCount < 0 || c.ValidationCoveredCount > c.ValidationSampleCount ||
		c.ValidationSampleCount > 10000 || c.CalibrationSampleCount > 10000-c.ValidationSampleCount ||
		!positive(c.TailCoverage) || c.TailCoverage < .95 || c.TailCoverage >= 1 ||
		float64(c.ValidationCoveredCount)/float64(c.ValidationSampleCount) < c.TailCoverage || !digest(c.ReportSHA256) ||
		c.MaxOtherModelRequests < 0 || c.MaxOtherModelRequests >= c.MaxActiveRequests ||
		!nonnegative(c.MaxOtherModelServiceFraction) || c.MaxOtherModelServiceFraction > 1 ||
		!sortedIDs(c.CompetitorProfileIDs) {
		return false
	}
	if !coverageConfidence(c.ValidationSampleCount, c.ValidationCoveredCount, c.TailCoverage) {
		return false
	}
	switch c.Contention {
	case "isolated":
		return c.MaxActiveRequests == 1 && c.MaxOtherModelRequests == 0 && c.MaxOtherModelServiceFraction == 0 && len(c.CompetitorProfileIDs) == 0
	case "same_model":
		return c.MaxActiveRequests >= 2 && c.MaxOtherModelRequests == 0 && c.MaxOtherModelServiceFraction == 0 && len(c.CompetitorProfileIDs) == 0
	case "other_model":
		return c.MaxOtherModelRequests > 0 && c.MaxOtherModelServiceFraction > 0 && len(c.CompetitorProfileIDs) > 0
	default:
		return false
	}
}

func sortedIDs(ids []string) bool {
	if len(ids) > 16 {
		return false
	}
	for i, id := range ids {
		if id == "" || len(id) > 256 || (i > 0 && ids[i-1] >= id) {
			return false
		}
	}
	return true
}

func digest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func positive(v float64) bool    { return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0) }
func nonnegative(v float64) bool { return v >= 0 && !math.IsNaN(v) && !math.IsInf(v, 0) }

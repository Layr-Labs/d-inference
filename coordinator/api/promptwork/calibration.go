package promptwork

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Calibration is immutable release data fitted on training prompts and checked
// on independent held-out prompts. The domain includes the exact tokenizer and
// template, model bytes, input estimate band and tools shape. Values outside
// that measured domain remain heuristic; no extrapolation or global haircut.
type Calibration struct {
	ID                     string       `json:"id"`
	ModelID                string       `json:"model_id"`
	ModelArtifactHash      string       `json:"model_artifact_hash"`
	PromptContractID       string       `json:"prompt_contract_id"`
	ReportSHA256           string       `json:"report_sha256"`
	MinEstimatedTokens     int          `json:"min_estimated_tokens"`
	MaxEstimatedTokens     int          `json:"max_estimated_tokens"`
	HasTools               bool         `json:"has_tools"`
	ShapeDomain            *ShapeDomain `json:"shape_domain"`
	MedianRatio            float64      `json:"median_ratio"`
	UpperRatio             float64      `json:"upper_ratio"`
	UpperAdditiveTokens    float64      `json:"upper_additive_tokens"`
	TrainingSamples        int          `json:"training_samples"`
	ValidationSamples      int          `json:"validation_samples"`
	ValidationCovered      int          `json:"validation_covered"`
	TailCoverageLowerBound float64      `json:"tail_coverage_lower_bound"`
}

func (c Calibration) Estimate(model, artifact, contract string, estimate int, hasTools bool, shape Shape) *protocol.PromptWork {
	if c.ModelID != model || c.ModelArtifactHash != artifact || c.PromptContractID != contract ||
		!c.ShapeDomain.Contains(shape) || c.HasTools != hasTools || c.MinEstimatedTokens <= 0 || c.MaxEstimatedTokens < c.MinEstimatedTokens ||
		estimate < c.MinEstimatedTokens || estimate > c.MaxEstimatedTokens ||
		c.TrainingSamples < 20 || c.TrainingSamples > 10000 || c.ValidationSamples < 59 || c.ValidationSamples > 10000 || c.ValidationCovered < 0 || c.ValidationCovered > c.ValidationSamples || float64(c.ValidationCovered)/float64(c.ValidationSamples) < .95 ||
		!finitePositive(c.MedianRatio) || !finitePositive(c.UpperRatio) || c.UpperRatio < c.MedianRatio ||
		!finiteNonnegative(c.UpperAdditiveTokens) || c.TailCoverageLowerBound < .95 || c.TailCoverageLowerBound >= 1 ||
		math.IsNaN(c.TailCoverageLowerBound) || !digest(c.ReportSHA256) {
		return nil
	}
	// Independently check that P[X >= observed successes | p=claimed lower bound] <= .05.
	// This prevents a hand-edited claimed lower bound from qualifying weak data.
	if binomialSurvival(c.ValidationSamples, c.ValidationCovered, c.TailCoverageLowerBound) > .05 {
		return nil
	}
	center := math.Ceil(float64(estimate) * c.MedianRatio)
	upper := math.Ceil(float64(estimate)*c.UpperRatio + c.UpperAdditiveTokens)
	if !finitePositive(center) || !finitePositive(upper) || upper > protocol.MaxPromptWorkTokens {
		return nil
	}
	work := &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkCalibrated,
		PromptTokens: int(center), UpperBoundTokens: int(upper), ModelArtifactHash: artifact,
		PromptContractID: contract, CalibrationID: c.ID}
	if !work.IsQualifiedFor(artifact, contract) {
		return nil
	}
	return work
}

func binomialSurvival(n, k int, p float64) float64 {
	if k <= 0 {
		return 1
	}
	// Log-space summation is stable for receipt-sized independent samples.
	maximum := math.Inf(-1)
	terms := make([]float64, 0, n-k+1)
	lgN, _ := math.Lgamma(float64(n + 1))
	for i := k; i <= n; i++ {
		lgI, _ := math.Lgamma(float64(i + 1))
		lgRest, _ := math.Lgamma(float64(n - i + 1))
		term := lgN - lgI - lgRest + float64(i)*math.Log(p) + float64(n-i)*math.Log1p(-p)
		terms = append(terms, term)
		maximum = math.Max(maximum, term)
	}
	sum := 0.0
	for _, term := range terms {
		sum += math.Exp(term - maximum)
	}
	return math.Exp(maximum) * sum
}
func finitePositive(value float64) bool {
	return value > 0 && !math.IsInf(value, 0) && !math.IsNaN(value)
}
func finiteNonnegative(value float64) bool {
	return value >= 0 && !math.IsInf(value, 0) && !math.IsNaN(value)
}
func digest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func Calibrated(model, artifact, contract string, estimate int, hasTools bool, shape Shape) *protocol.PromptWork {
	var result *protocol.PromptWork
	for _, c := range reviewedCalibrations {
		if work := c.Estimate(model, artifact, contract, estimate, hasTools, shape); work != nil &&
			(result == nil || work.UpperBoundTokens > result.UpperBoundTokens) {
			result = work
		}
	}
	return result
}

// HasCalibrations avoids parsing a body when there is no reviewed fallback.
func HasCalibrations() bool { return len(reviewedCalibrations) > 0 }

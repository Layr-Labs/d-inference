package performance

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// CalibrationEvidence is the detached work and applicability evidence already
// captured in the provider critical section. It carries no mutable owner state.
type CalibrationEvidence struct {
	Calibration               *firstcontent.Calibration
	ArtifactSHA256            string
	ConfiguredContextTokens   int
	Work                      firstcontent.Work
	WorkKnown                 bool
	HasCapacity               bool
	CapacityAgeMS             int32
	ModelLoaded               bool
	PromptWorkArtifactHash    string
	PromptWorkContractID      string
	PerformanceAgeMS          int32
	IsolatedPrefillTPS        float64
	IsolatedInitialized       bool
	ContendedPerformanceAgeMS int32
	ContendedPrefillTPS       float64
	DecodeTPS                 float64
}

type IncomingWork struct {
	RequiresVision     bool
	PromptWork         *protocol.PromptWork
	PromptTokens       int
	CachedTokens       float64
	RequestedMaxTokens int
}

// PredictCalibrated prices incoming prompt work and only a bounded early
// decode, never the incoming completion's entire memory commitment.
func PredictCalibrated(e CalibrationEvidence, incoming IncomingWork, capacityFreshness, performanceFreshness time.Duration, decodeAllowance int) (firstcontent.Prediction, int32, bool) {
	calibration := e.Calibration
	if calibration == nil || !e.WorkKnown ||
		!e.HasCapacity || e.CapacityAgeMS < 0 || time.Duration(e.CapacityAgeMS)*time.Millisecond > capacityFreshness ||
		!e.ModelLoaded || incoming.RequiresVision ||
		!incoming.PromptWork.IsQualifiedFor(e.PromptWorkArtifactHash, e.PromptWorkContractID) ||
		!incoming.PromptWork.IsQualifiedFor(e.ArtifactSHA256, calibration.PromptContractID) ||
		incoming.PromptTokens != incoming.PromptWork.UpperBoundTokens {
		return firstcontent.Prediction{}, -1, false
	}
	work := e.Work
	work.PromptTokens = incoming.PromptTokens
	work.CacheState = "cold"
	if incoming.CachedTokens > 0 {
		work.CacheState = "reused"
	}
	work.Contention = "isolated"
	age, rate := e.PerformanceAgeMS, e.IsolatedPrefillTPS
	if work.ActiveRequests > 0 {
		work.Contention = "same_model"
		if work.OtherModelRequests > 0 {
			work.Contention = "other_model"
		}
		age, rate = e.ContendedPerformanceAgeMS, e.ContendedPrefillTPS
	} else if !e.IsolatedInitialized {
		return firstcontent.Prediction{}, -1, false
	}
	if age < 0 || time.Duration(age)*time.Millisecond > performanceFreshness || !capacityvalue.FinitePositive(rate) || !capacityvalue.FinitePositive(e.DecodeTPS) {
		return firstcontent.Prediction{}, -1, false
	}
	work.PrefillTokens += max(0, float64(incoming.PromptTokens)-incoming.CachedTokens)
	decodeTokens := decodeAllowance
	if incoming.RequestedMaxTokens > 0 {
		decodeTokens = min(decodeTokens, incoming.RequestedMaxTokens)
	}
	// Check before addition: overflow and runtime ceilings cannot borrow a cell.
	if decodeTokens > e.ConfiguredContextTokens || incoming.PromptTokens > e.ConfiguredContextTokens-decodeTokens {
		return firstcontent.Prediction{}, -1, false
	}
	work.ContextTokens = max(incoming.PromptTokens+decodeTokens, work.ContextTokens)
	work.DecodeTokens += float64(decodeTokens)
	work.ActiveRequests++
	work.ObservedPrefillTPS, work.ObservedDecodeTPS = rate, e.DecodeTPS
	prediction, ok := calibration.Predict(work)
	return prediction, age, ok
}

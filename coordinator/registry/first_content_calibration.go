package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// calibratedFirstContentPrediction replaces the legacy rate margin only inside
// an exact reviewed envelope. The snapshot owns all existing work; this adds
// just the incoming prompt and a bounded first-content decode allowance.
func calibratedFirstContentPrediction(s *routingSnapshot, pr *PendingRequest, prompt int, cached float64) (firstcontent.Prediction, int32, bool) {
	profile := s.deadlineProfile
	if profile == nil || profile.DeadlineCalibration == nil || !s.calibratedWorkKnown ||
		!s.hasBackendCapacity || s.capacityAgeMs < 0 || time.Duration(s.capacityAgeMs)*time.Millisecond > firstContentFreshness ||
		!s.modelLoaded || pr.RequiresVision ||
		!pr.PromptWork.IsQualifiedFor(profile.ArtifactSHA256, profile.DeadlineCalibration.PromptContractID) ||
		prompt != pr.PromptWork.UpperBoundTokens {
		return firstcontent.Prediction{}, -1, false
	}
	work := s.calibratedWork
	work.PromptTokens = prompt
	work.CacheState = "cold"
	if cached > 0 {
		work.CacheState = "reused"
	}
	work.Contention = "isolated"
	age, rate := s.performanceAgeMs, s.isolatedPrefillTPS
	if work.ActiveRequests > 0 {
		work.Contention = "same_model"
		if work.OtherModelRequests > 0 {
			work.Contention = "other_model"
		}
		age, rate = s.contendedPerformanceAgeMs, s.contendedPrefillTPS
	} else if !s.isolatedPrefillInitialized {
		return firstcontent.Prediction{}, -1, false
	}
	if age < 0 || time.Duration(age)*time.Millisecond > firstContentPerformanceFreshness || !finitePositive(rate) || !finitePositive(s.calibratedDecodeTPS) {
		return firstcontent.Prediction{}, -1, false
	}
	work.PrefillTokens += max(0, float64(prompt)-cached)
	decodeTokens := firstContentDecodeAllowance
	if pr.RequestedMaxTokens > 0 {
		decodeTokens = min(decodeTokens, pr.RequestedMaxTokens)
	}
	// The priced early decode runs beyond the input context. Check before
	// addition so neither overflow nor the runtime ceiling can borrow a cell.
	if decodeTokens > profile.ConfiguredContextTokens || prompt > profile.ConfiguredContextTokens-decodeTokens {
		return firstcontent.Prediction{}, -1, false
	}
	work.ContextTokens = max(prompt+decodeTokens, work.ContextTokens)
	work.DecodeTokens += float64(decodeTokens)
	work.ActiveRequests++
	work.ObservedPrefillTPS, work.ObservedDecodeTPS = rate, s.calibratedDecodeTPS
	prediction, ok := profile.DeadlineCalibration.Predict(work)
	return prediction, age, ok
}

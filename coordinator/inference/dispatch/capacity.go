package dispatch

import (
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// hardTTFTGateApplies reports whether the scheduler's token-prefill estimate is
// authoritative enough to reject this request before dispatch. Media requests
// run CPU decode plus a separate vision tower before text prefill; neither cost
// exists in estimatedTTFTFromSnapshot, so treating that partial estimate as a
// hard ceiling rejects healthy video/image requests on a number that cannot
// predict their TTFT. They still use the best-available provider and remain
// bounded by the same request-absolute first-content deadline.
func (s *Controller) HardTTFTGateApplies(requiresVision bool) bool {
	return s.deps.TTFTHardReject() && !requiresVision
}

func (s *Controller) estimateTTFTRetryAfter(model string, bestTTFT, threshold time.Duration) int {
	overage := bestTTFT - threshold
	seconds := int(math.Ceil(overage.Seconds()))
	if base := s.EstimateRetryAfter(model); seconds < base {
		seconds = base
	}
	if seconds < 2 {
		seconds = 2
	}
	if seconds > 30 {
		seconds = 30
	}
	return seconds
}

func (s *Controller) WriteTTFTTooSlow(w http.ResponseWriter, model, publicModel string, bestTTFT, threshold time.Duration) {
	retryAfter := s.estimateTTFTRetryAfter(model, bestTTFT, threshold)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	s.deps.Counters.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:ttft_429"})
	httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
		ttftTooSlowMessage(publicModel, bestTTFT, threshold, retryAfter),
		httpresponse.WithCode("rate_limit_exceeded")))
}

func (s *Controller) TriggerWarmPool() {
	if s == nil || s.deps.Registry() == nil {
		return
	}
	s.deps.Registry().RequestWarmPoolTrigger()
}

func (s *Controller) recordWarmPoolQueueState(model string) {
	if s == nil || s.deps.Registry() == nil || s.deps.Registry().Queue() == nil {
		return
	}
	depth, oldest := s.deps.Registry().Queue().QueueStats(model)
	if depth <= 0 {
		s.deps.Registry().RecordWarmPoolQueueCleared(model)
		return
	}
	s.deps.Registry().RecordWarmPoolQueueEnqueued(model, depth, oldest)
	s.TriggerWarmPool()
}

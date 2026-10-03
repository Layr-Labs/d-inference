package inference

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// admissionScanPermit bounds CPU fleet walks. External prompt planning and
// fallback body preparation release it, then acquire against the remaining
// request clock before another walk. A failed acquisition writes the terminal
// response (or silently refunds a cancelled request) exactly once.
type admissionScanPermit struct {
	server *Owner
	w      http.ResponseWriter
	r      *http.Request
	parsed map[string]any
	params inferenceAdmissionParams
	held   bool
}

func (p *admissionScanPermit) acquire(model string) bool {
	if p.held {
		return true
	}
	if p.r.Context().Err() != nil {
		p.params.refundReservation()
		return false
	}
	s := p.server
	switch s.acquireRoutingScanSlot(preflightScanWait(p.params.remainingFirstContentBudget()), p.r.Context().Done()) {
	case scanSlotAcquired:
		p.held = true
		return true
	case scanSlotClientGone:
		p.params.refundReservation()
		return false
	default:
		p.params.refundReservation()
		retryAfter := s.estimateRetryAfter(model)
		p.w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
		s.observation.Incr("routing.scan_admission_timeout", []string{"model:" + model, "stage:preflight"})
		s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:routing_saturated"})
		s.recordRejection(rejectionInfo{
			r:                     p.r,
			stage:                 "preflight_capacity",
			reasonCode:            rejectionReasonRoutingSaturated,
			httpStatus:            http.StatusTooManyRequests,
			keyID:                 access.KeyIDFromContext(p.r.Context()),
			consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(p.r.Context())),
			requestedModel:        p.params.publicModel,
			resolvedModel:         model,
			stream:                p.params.stream,
			estimatedPromptTokens: p.params.estimatedPromptTokens,
			requestedMaxTokens:    p.params.requestedMaxTokens,
			requiresVision:        p.params.requiresVision,
			hasTools:              p.params.hasTools,
			retryAfterMs:          retryAfter * 1000,
			params:                rejectionSamplingParams(p.parsed),
			// Saturation must not trigger another fleet walk for diagnostics.
			skipServability: true,
		})
		httpx.WriteJSON(p.w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded",
			"the coordinator is at routing capacity — please retry", httpx.WithCode("rate_limit_exceeded")))
		return false
	}
}

func (p *admissionScanPermit) release() {
	if p.held {
		p.server.releaseRoutingScanSlot()
		p.held = false
	}
}

package inference

import (
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// preflightScanWait is the admission gate's slot-wait budget: a short slice
// (a quarter) of the request's first-content deadline, capped at one second.
// Under saturation admission must shed FAST — a fast 429 relieves CPU — while
// a dispatch attempt may park for its whole remaining budget. Requests
// without a deadline (bare fixtures) get a 250ms slice.
func preflightScanWait(deadline time.Duration) time.Duration {
	return scangate.PreflightWait(deadline)
}

// admissionScanPermit bounds CPU fleet walks. External prompt planning and
// fallback body preparation release it, then acquire against the remaining
// request clock before another walk. A failed acquisition writes the terminal
// response (or silently refunds a cancelled request) exactly once.
type admissionScanPermit struct {
	admission *Admission
	w         http.ResponseWriter
	r         *http.Request
	parsed    map[string]any
	params    AdmissionRequest
	held      bool
}

func (p *admissionScanPermit) acquire(model string) bool {
	if p.held {
		return true
	}
	if p.r.Context().Err() != nil {
		p.params.RefundReservation()
		return false
	}
	s := p.admission.owner
	switch s.acquireRoutingScanSlot(preflightScanWait(p.params.remainingFirstContentBudget()), p.r.Context().Done()) {
	case scanSlotAcquired:
		p.held = true
		return true
	case scanSlotClientGone:
		p.params.RefundReservation()
		return false
	default:
		p.params.RefundReservation()
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
			requestedModel:        p.params.PublicModel,
			resolvedModel:         model,
			stream:                p.params.Stream,
			estimatedPromptTokens: p.params.EstimatedPromptTokens,
			requestedMaxTokens:    p.params.RequestedMaxTokens,
			requiresVision:        p.params.RequiresVision,
			hasTools:              p.params.HasTools,
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
		p.admission.owner.releaseRoutingScanSlot()
		p.held = false
	}
}

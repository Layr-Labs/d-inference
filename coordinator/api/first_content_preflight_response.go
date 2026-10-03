package api

import (
	"fmt"
	"net/http"
	"strconv"
)

// An expired renderer-specific clock cannot be soft-served or cold-spilled on
// another renderer's live envelope. Keep the retryable capacity response while
// distinguishing elapsed time from absent providers or unknown performance.
func (s *Server) writeFirstContentDeadlineExpired(w http.ResponseWriter, model, publicModel string) {
	retryAfter := s.estimateRetryAfter(model)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_429"})
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		fmt.Sprintf("the first-content deadline has expired for every eligible provider of model %q; retry after %ds", publicModel, retryAfter),
		withCode("rate_limit_exceeded")))
}

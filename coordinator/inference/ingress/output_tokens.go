package ingress

import (
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/store"
	"math"
	"net/http"
)

// estimateRequestedMaxTokens reports whether the selected output bound times
// the choice count fits in an int. Overflow is invalid input, not a token value
// that can safely continue into quota, price or capacity arithmetic.
func estimateRequestedMaxTokens(parsed map[string]any) (int, bool) {
	maxTokens := 256
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			maxTokens = n
			break
		}
	}
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		if maxTokens > math.MaxInt/copies {
			return 0, false
		}
		return maxTokens * copies, true
	}
	return maxTokens, true
}

func (s *Controller) validateRequestedMaxTokens(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string) (int, bool) {
	if tokens, ok := estimateRequestedMaxTokens(parsed); ok {
		return tokens, true
	}
	copies, _ := intFromRequestValue(parsed["n"])
	stream, _ := parsed["stream"].(bool)
	s.deps.Observer.Rejection(dispatch.Rejection{
		Request:         r,
		Stage:           "validation",
		ReasonCode:      "bad_param",
		HttpStatus:      http.StatusBadRequest,
		KeyID:           requestcontext.KeyID(r.Context()),
		ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
		RequestedModel:  publicModel,
		ResolvedModel:   model,
		Stream:          stream,
		N:               copies,
		Params:          rejectionSamplingParams(parsed),
	})
	httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
		"n times the requested output token limit exceeds the supported integer range", httpresponse.WithParam("n")))
	return 0, false
}

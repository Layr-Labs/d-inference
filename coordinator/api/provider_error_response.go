package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// writeGenericProviderError writes the terminal HTTP body for a provider error
// on paths WITHOUT a failover ladder or in-band SSE error framing: the generic
// inference handlers (/v1/messages, /v1/completions) and the non-streaming
// chat response assembly. Deterministic non-provider-fault reasons surface the
// SAME curated bodies as the chat dispatch ladder — a jinja_* template-render
// failure becomes the 422 model_capability invalid_request_error (the raw
// template backtrace never reaches a client), gated by the ladder's
// EIGENINFERENCE_JINJA_TERMINAL_REJECT kill switch; tool_noncompliance keeps
// its provider-typed 422 message (already curated and content-free) but in the
// invalid_request_error/model_capability envelope instead of provider_error.
// Every other error is mapped from the closed failure_code vocabulary. Raw
// provider prose is never passed through.
func (s *Server) writeGenericProviderError(w http.ResponseWriter, errMsg protocol.InferenceErrorMessage) {
	errMsg = attempt.NormalizeInferenceErrorForInternalUse(errMsg)
	if dispatch.JinjaTerminalRejectEnabled() && attempt.IsJinjaTemplateErrorReason(errMsg.ErrorReason) {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", dispatch.JinjaTerminalRejectMessage, withCode("model_capability")))
		return
	}
	if attempt.NormalizeInferenceErrorReason(errMsg.ErrorReason) == attempt.ErrorReasonToolNoncompliance {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", response.ClientSafeInferenceErrorMessage(errMsg), withCode("model_capability")))
		return
	}
	statusCode := errMsg.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusBadGateway
	}
	writeJSON(w, statusCode, errorResponse("provider_error", response.ClientSafeInferenceErrorMessage(errMsg)))
}

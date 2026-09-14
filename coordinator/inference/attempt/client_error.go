package attempt

import (
	"net/http"
)

// isTerminalClientErrorCode reports whether a provider-returned status code is a
// DETERMINISTIC client-shape rejection that fails identically on every provider,
// so the dispatch loop must stop and return it ONCE rather than fail over.
//
// Set: 400 (invalidRole / invalidToolPayload / mediaUnsupportedByModel + all VLM
// client MediaError), plus 413/415 defensively (unambiguous client shapes; not
// emitted by the provider map today but correct if a future version does).
//
// EXCLUDES 422 deliberately: the provider maps invalidResponseFormatOutput→422,
// which is thrown for BOTH a deterministic request-shape fault ("json_schema
// requires a json_schema payload") AND a model-OUTPUT-validation fault ("model
// output was not valid JSON"). The latter depends on what the model GENERATED, so
// a re-sample at temperature>0 (or a different provider/model) could succeed —
// stopping it would turn a recoverable request into a lost success (hurting
// uptime). 422 therefore stays on the normal failover path.
//
// Also EXCLUDES 404 ("model not loaded" — a cold-miss/lifecycle that MUST fail
// over, and which matches the "not loaded" capacity marker), 408 and 429
// (transient). 402 (the only coordinator-emitted 4xx) is excluded, so a code in
// this set can ONLY originate from a provider InferenceErrorMessage.
func IsTerminalClientErrorCode(code int) bool {
	switch code {
	case http.StatusBadRequest, // 400
		http.StatusRequestEntityTooLarge, // 413
		http.StatusUnsupportedMediaType:  // 415
		return true
	}
	return false
}

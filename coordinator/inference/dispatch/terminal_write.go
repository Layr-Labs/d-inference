package dispatch

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// preContentTerminal writes a terminal response for a request that has not yet
// streamed any content. No pre-content path writes headers or bytes, so this
// function always retains ownership of the real terminal HTTP status.
//
// retryAfterSec <= 0 omits the Retry-After header.
func (d *execution) preContentTerminal(
	info Rejection,
	retryAfterSec int,
	errType, message, code string,
) {
	d.s.deps.Observer.Rejection(info)
	if retryAfterSec > 0 {
		d.w.Header().Set("Retry-After", strconv.Itoa(retryAfterSec))
	}
	httpresponse.WriteJSON(d.w, info.HttpStatus, httpresponse.ErrorBody(errType, message, httpresponse.WithCode(code)))
}

// ttftTooSlowTerminal is the fleet-wide TTFT rejection in pre-content terminal
// form: every eligible provider is above the deadline, which is deterministic,
// so the caller stops rather than retrying the same doomed scan.
func (d *execution) ttftTooSlowTerminal(info Rejection, retryAfterSec int, message string) {
	d.s.deps.Counters.Incr("routing.decisions", []string{
		"model:" + d.model,
		"model_type:" + d.s.deps.Registry().ModelType(d.model),
		"outcome:ttft_429",
	})
	info.HttpStatus = http.StatusTooManyRequests
	d.preContentTerminal(info, retryAfterSec, "rate_limit_exceeded", message, "rate_limit_exceeded")
}

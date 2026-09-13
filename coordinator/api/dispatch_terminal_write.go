package api

import (
	"net/http"
	"strconv"
)

// preContentTerminal writes a terminal response for a request that has not yet
// streamed any content. No pre-content path writes headers or bytes, so this
// function always retains ownership of the real terminal HTTP status.
//
// retryAfterSec <= 0 omits the Retry-After header.
func (d *dispatchState) preContentTerminal(
	info rejectionInfo,
	retryAfterSec int,
	errType, message, code string,
) {
	d.s.recordRejection(info)
	if retryAfterSec > 0 {
		d.w.Header().Set("Retry-After", strconv.Itoa(retryAfterSec))
	}
	writeJSON(d.w, info.httpStatus, errorResponse(errType, message, withCode(code)))
}

// ttftTooSlowTerminal is the fleet-wide TTFT rejection in pre-content terminal
// form: every eligible provider is above the deadline, which is deterministic,
// so the caller stops rather than retrying the same doomed scan.
func (d *dispatchState) ttftTooSlowTerminal(info rejectionInfo, retryAfterSec int, message string) {
	d.s.ddIncr("routing.decisions", []string{
		"model:" + d.model,
		"model_type:" + d.s.registry.ModelType(d.model),
		"outcome:ttft_429",
	})
	info.httpStatus = http.StatusTooManyRequests
	d.preContentTerminal(info, retryAfterSec, "rate_limit_exceeded", message, "rate_limit_exceeded")
}

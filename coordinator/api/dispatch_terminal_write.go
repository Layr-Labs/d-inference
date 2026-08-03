package api

import (
	"net/http"
	"strconv"
)

// Pre-content terminal responses.
//
// The prefill SSE keepalive starts before provider selection so its timer covers
// the coordinator's own routing work and the queue wait, not just provider
// prefill (see dispatchState.startPrefillKeepalive). That means a capacity or
// availability verdict reached late — a queue timeout, a full queue, a
// fleet-wide TTFT rejection — can now land on a request whose HTTP 200 a
// keepalive already committed.
//
// Once committed the status code is frozen. Writing a second status here would
// produce a superfluous-WriteHeader and hand the caller a malformed response, so
// the identical failure goes out in-band as an SSE error event instead.
//
// Measured on 2026-07-29: 99.5% of 429 verdicts are reached within 5s of request
// arrival while the first keepalive comment lands ~8.9s in, so this in-band arm
// is a correctness backstop for the narrow overlap, not the common path.

// preContentTerminal writes a terminal response for a request that has not yet
// streamed any content, choosing the status-coded or in-band form based on
// whether a prefill keepalive already committed HTTP 200. It owns the rejection
// ledger write so the ledger and the OR-uptime counter cannot disagree about
// what the caller actually received.
//
// retryAfterSec <= 0 omits the Retry-After header. The keepalive is stopped on
// every path, which is also what guarantees its goroutine cannot interleave a
// comment with the response written here.
func (d *dispatchState) preContentTerminal(
	info rejectionInfo,
	retryAfterSec int,
	errType, message, code string,
) {
	frozen := d.keepalive.takeOver()

	// A frozen response is not the status class the ledger row names: a 429 that
	// reached the caller as a broken stream is not a rate-limit it can cleanly
	// fail over. Book it as mid-stream, and suppress recordRejection's own
	// status-derived emission so the request is counted exactly once.
	info.suppressOutcome = frozen
	d.s.recordRejection(info)

	if !frozen {
		if retryAfterSec > 0 {
			d.w.Header().Set("Retry-After", strconv.Itoa(retryAfterSec))
		}
		writeJSON(d.w, info.httpStatus, errorResponse(errType, message, withCode(code)))
		return
	}

	d.s.recordRequestOutcome(d.model, d.kvBackendAttribution(), orClassMidStream)
	if d.isResponsesAPI {
		writeResponsesSSEErrorEvent(d.w, errType, message)
		return
	}
	writeSSEErrorEvent(d.w, errorResponse(errType, message, withCode(code)))
}

// startPrefillKeepalive arms the prefill SSE keepalive for a streaming request,
// once per request.
//
// It runs BEFORE the dispatch loop deliberately. Production measurement on
// 2026-07-29 showed the requests OpenRouter abandoned spent 3.9s in coordinator
// routing and a further 4.3s queued — 8.2s — before a provider was ever
// selected. Arming the timer at selection therefore scheduled the first comment
// at ~13.1s against a ~10s client deadline, so the keepalive never fired on the
// requests that needed it, while requests that routed quickly (0.7s queue) were
// covered and survived. Arming here makes the timer cover the whole pre-content
// window.
//
// Callers that write a terminal response before any content must go through
// preContentTerminal, which handles the case where this keepalive has already
// committed the 200.
func (d *dispatchState) startPrefillKeepalive() {
	if !d.stream || d.keepalive != nil || d.s.prefillKeepaliveInterval <= 0 {
		return
	}
	// The provider job id does not exist until a provider is selected, so a
	// keepalive that commits during routing or the queue omits
	// X-Inference-Job-ID — the same trade already documented for the attestation
	// and X-Timing headers on keepalive-committed responses.
	d.keepalive = d.s.newPrefillKeepaliver(d.w, d.requestID)
	d.keepalive.start(d.r.Context())
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

package dispatch

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// run is the dispatch orchestrator. It replaces the giant inline `for attempt :=
// range maxDispatchAttempts { ... }` block plus the post-loop !committed ladder,
// attestation headers, timing header, settlement defer, and final response handoff.
func (d *execution) run() {
	s := d.s
	defer d.finalizeProfile()
	w, r := d.w, d.r
	d.preflightLegacyCacheBust()

	for attempt := range maxDispatchAttempts {
		d.attempt = attempt
		// Deadline-bounded failover: after the first attempt, stop failing over
		// once the request's deadline/context has fired (client gone or a request
		// timeout). We keep trying fresh healthy providers only while there is
		// time budget left. Candidate exhaustion is handled inside dispatchPrimary
		// (it returns outcomeFailFast as soon as no eligible provider remains), so
		// in practice the loop ends at exhaustion or success; maxDispatchAttempts
		// is only a hot-loop ceiling and this is the wall-clock bound.
		if attempt > 0 && r.Context().Err() != nil {
			// The client left between attempts (D2). There is no in-flight
			// provider (the previous attempt already cleaned up and wrote its
			// own route outcome) and nobody to write a 429/5xx to, so record it
			// as client_gone like every other pre-content cancel arm — not as
			// the exhausted ladder's rate_limited / provider_5xx outcome.
			d.refundReservation()
			d.emitClientGone(phaseBeforeFirstToken)
			return
		}
		if attempt > 0 && d.firstTokenExpired() {
			// The request-absolute first-token budget is gone: the client must
			// see the retryable 429 (synthetic 504 -> first_chunk_timeout), not
			// whatever the last provider attempt happened to fail with.
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			goto exhausted
		}
		// Each attempt holds preamble chunks from its own provider only.
		d.heldChunks = nil

		switch d.dispatchPrimary() {
		case outcomeRetry:
			continue
		case outcomeFailFast:
			goto exhausted
		case outcomeResponseWritten, outcomeClientGone:
			return
		case outcomeProceed:
			// fall through to the first-chunk wait below
		}

		d.requestID = d.pr.RequestID
		// d.pr.Attempt is already stamped at PendingRequest construction in
		// dispatchOneProvider (and on the queued path), before the provider send —
		// so it is never written here, where it would race handleComplete.
		if d.timing.RoutedAt.IsZero() {
			d.timing.RoutedAt = time.Now()
		}
		d.emitRouteLatency()

		s.deps.Counters.Incr("routing.decisions", []string{"model:" + d.model, "outcome:selected"})
		s.deps.Counters.Incr("routing.provider_selected", []string{"provider_id:" + d.provider.ID, "model:" + d.model})

		s.deps.Logger().Info("inference request dispatched",
			"trace_id", requestcontext.RequestID(r.Context()),
			"request_id", d.requestID,
			"model", d.model,
			"provider_id", d.provider.ID,
			"stream", d.stream,
			"attempt", attempt+1,
		)

		s.deps.Logger().Info("dispatch_pool",
			"model", d.model,
			"ttft_deadline_ms", d.deadline.Milliseconds(),
			"speculative_at_ms", d.speculativeAt.Milliseconds(),
		)

		if d.firstTokenExpired() {
			// A token that is already buffered beats the clock: deliver it
			// instead of 429ing a request the provider answered on time.
			if chunk, ok := drainReadyFirstContent(d.pr, &d.heldChunks); ok {
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				break
			}
			if d.abandonInflightForFirstTokenTimeout() {
				goto exhausted
			}
		}

		// ---- Speculative TTFT-aware first-chunk wait ----
		switch d.waitFirstChunk() {
		case outcomeRetry:
			// Post-dispatch provider failure. Stop failing over when the request is
			// unservable (deterministic context overflow, or a capacity transient
			// past maxCapacityClassRetries) so we don't storm all 64 providers; the
			// exhausted ladder then emits one uptime-neutral 429. Faults/timeouts
			// return false and keep failing over as before.
			if d.shouldStopFailover() {
				goto exhausted
			}
			continue
		case outcomeClientGone:
			return
		case outcomeAccepted:
			// Provider accepted or held preamble but hasn't produced content.
			switch d.waitAccepted() {
			case outcomeRetry:
				if d.shouldStopFailover() {
					goto exhausted
				}
				continue
			case outcomeClientGone:
				return
			}
		}

		break
	}

exhausted:
	if !d.committed {
		d.refundReservation()
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
		}
		failure, stickyFault := d.terminalFailureForExhaustion()
		statusCode, reason, timeoutReclassified, dominance :=
			d.resolveDominantExhaustedStatus(failure, stickyFault)
		if timeoutReclassified {
			s.deps.Counters.Incr("routing.first_chunk_timeout_reclassified", []string{"model:" + d.model, "reason:" + reason})
		}
		switch dominance {
		case exhaustedClientError:
			// Deterministic provider client 4xx (identical fleet-wide): pass the real
			// code through ONCE. Checked BEFORE d.unservable / statusCode==0 so it can
			// never be reclassified to 429/503 — this is a client fault, not capacity.
			s.deps.Counters.Incr("routing.client_error_passthrough", []string{"model:" + d.model, "code:" + strconv.Itoa(statusCode)})
		case exhaustedGenuineFault:
			// A genuine provider fault observed on any pre-content attempt is
			// request-terminal precedence. Later neutral deadline/capacity
			// refusals still own their own route rows but cannot hide the fault.
		case exhaustedUnservable:
			// The loop stopped early because no provider can serve this request
			// (deterministic context overflow, or a capacity transient that
			// exhausted maxCapacityClassRetries). We already know the verdict, so
			// skip the quick-capacity probe and the 5xx→429 reclassification below:
			// emit a single uptime-neutral 429. This is the proactive complement to
			// the always-on backstop — it converts the request BEFORE storming the
			// fleet, not after 64 attempts.
			s.deps.Counters.Incr("routing.oversized_request_rejected", []string{"model:" + d.model, "stage:dispatch"})
		case exhaustedDeadline:
			// Every refusal was health-neutral and did not consume the generic
			// capacity retry cap. Once no untried candidate remains, expose one
			// uptime-neutral 429 with its own closed reason.
			s.deps.Counters.Incr("routing.deadline_unreachable_rejected", []string{"model:" + d.model, "stage:dispatch"})
		case exhaustedUndecided:
			if statusCode == 0 {
				// Distinguish capacity exhaustion (429) from genuine unavailability (503).
				// A quick capacity check tells us if providers exist but are full.
				_, capRej, _ := s.deps.Registry().QuickCapacityCheckForRequest(
					d.model, d.estimatedPromptTokens, d.requestedMaxTokens,
					d.traits(), d.requiresVision, d.allowedProviderSerials...)
				if capRej > 0 {
					statusCode = http.StatusTooManyRequests
				} else {
					statusCode = http.StatusServiceUnavailable
				}
			} else if statusCode >= 500 && attemptpolicy.IsCapacityClassProviderError(failure.errText) {
				// Backstop (always on): the provider admitted the request then
				// rejected it because (prompt+max_tokens) overflowed its token budget /
				// KV / context — a capacity condition, not a server fault. Return an
				// uptime-neutral 429 (OpenRouter fails over) instead of the raw 5xx,
				// which would count against our uptime. Fires only on a real provider
				// rejection, so it cannot over-reject servable traffic.
				statusCode = http.StatusTooManyRequests
				reason = "unservable_token_budget"
				s.deps.Counters.Incr("routing.unservable_reclassified", []string{"model:" + d.model})
			}
		}
		s.deps.Observer.CoordinatorExhausted(r.Context(), reason == "dispatch_exhausted" && dominance == exhaustedUndecided && failure.statusCode == 0)
		// Resolved once: the telemetry event and the OR-uptime counter must agree
		// on which slot's backend this failure belongs to, and on whether that
		// backend was chosen or degraded into (v0.8.0 paged rollout).
		kvBackend := d.exhaustedKVBackendAttribution(failure, stickyFault)
		s.deps.Observer.Event(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", d.exhaustionAttemptCount()),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     d.exhaustionAttemptCount(),
				"status_code": statusCode,
				"last_error":  failure.errText,
				"kv_backend":  kvBackend.Backend,
			})
		if s.deps.Metrics() != nil {
			s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "failure"})
		}
		s.deps.Counters.Incr("inference.dispatches", []string{"status:failure"})
		// OR-uptime outcome for a dispatched-but-failed request (exactly once;
		// pre-dispatch rejections emit from recordRejection instead).
		d.recordDispatchedRequestOutcome(kvBackend, ClassifyOutcomeByCode(statusCode))
		d.recordRequestOutcomeORView(ClassifyOutcomeByCode(statusCode))
		if statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable {
			retryAfter := s.EstimateRetryAfter(d.model)
			if d.lastErrFeasibleAfterMS > 0 {
				// Enriched rejection (routing v2): the rejecting provider
				// forecast when a request of this shape could next be admitted
				// — an honest Retry-After beats the queue-depth heuristic.
				// Clamped to the heuristic's own [2,30]s band so a
				// provider-authored value can neither hammer nor park clients.
				hinted := int((d.lastErrFeasibleAfterMS + 999) / 1000)
				if hinted < 2 {
					hinted = 2
				}
				if hinted > 30 {
					hinted = 30
				}
				retryAfter = hinted
			}
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			info := d.rejection("dispatch", reason, statusCode, retryAfter*1000)
			if !stickyFault && (d.unservable || failure.deadline) {
				// No provider could serve this request (it exceeds the model
				// context, or every attempted provider refused the remaining
				// deadline). Mark it not-servable so the rejection ledger's
				// counterfactual reflects the terminal decision.
				info.ServabilityComputed = true
				info.CandidateCount = 0
			}
			s.deps.Observer.Rejection(info)
		} else {
			s.deps.Observer.Rejection(d.rejection("dispatch", reason, statusCode, 0))
		}
		rateLimitMessage := fmt.Sprintf(
			"all providers at capacity after %d attempt(s): %s",
			d.exhaustionAttemptCount(), failure.errText)
		if reason == rejectionReasonDeadlineUnreachable {
			rateLimitMessage = fmt.Sprintf(
				"no provider could produce first content within the remaining deadline for model %q",
				d.publicModel)
		}
		if statusCode == http.StatusTooManyRequests {
			httpresponse.WriteJSON(w, statusCode, httpresponse.ErrorBody("rate_limit_exceeded",
				rateLimitMessage,
				httpresponse.WithCode("rate_limit_exceeded")))
		} else if d.terminalClientError {
			// Surface the provider's client-shape error verbatim as an
			// invalid_request_error, with no misleading "after N attempt(s)" framing
			// (it was returned once, deterministically). A jinja_* latch surfaces
			// the curated model_capability message instead of the provider's raw
			// template backtrace.
			if d.terminalClientErrorMessage != "" {
				errorCode := "model_capability"
				if d.terminalClientErrorReason == "payload_too_large" {
					errorCode = "payload_too_large"
				}
				httpresponse.WriteJSON(w, statusCode, httpresponse.ErrorBody(
					"invalid_request_error", d.terminalClientErrorMessage, httpresponse.WithCode(errorCode)))
			} else {
				httpresponse.WriteJSON(w, statusCode, httpresponse.ErrorBody("invalid_request_error", failure.errText))
			}
		} else {
			httpresponse.WriteJSON(w, statusCode, httpresponse.ErrorBody("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", d.exhaustionAttemptCount(), failure.errText)))
		}
		return
	}
	if s.deps.Metrics() != nil {
		s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "success"})
	}
	s.deps.Counters.Incr("inference.dispatches", []string{"status:success"})
	// OR-uptime outcome. For STREAMING this is a commit-time approximation (the
	// consumer got content; a later post-commit mid-stream failure is still counted
	// as success — the persisted route-outcome rows hold the exact breakdown). For
	// NON-streaming, "committed" only means a provider chunk arrived and the writer
	// can still fail with a 5xx/504, so the outcome is recorded in
	// writeCommittedResponse from the status it actually writes. Emitted exactly
	// once per dispatched request (disjoint from the exhausted branch above and
	// from pre-dispatch rejections).
	if d.stream {
		d.recordDispatchedRequestOutcome(d.KVBackendAttribution(), OrClassSuccess)
	}

	d.writeCommittedResponse()
}

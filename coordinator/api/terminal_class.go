package api

import "strings"

// statusClientClosedRequest is the de-facto standard (nginx-originated) HTTP
// status for "client closed request". The coordinator uses it both for genuine
// consumer disconnects and for coordinator-initiated aborts on the consumer's
// behalf (e.g. the chunk-buffer-overflow abort in handleChunk), so terminal
// classification treats it as a consumer-side outcome, never a provider fault.
const statusClientClosedRequest = 499

// errorClassConsumerCancelAfterCommit is the route-outcome error_class for a
// provider terminal that reports a consumer-side cancellation AFTER content
// was committed (client cancel, or the coordinator's overflow-499 abort of a
// stalled consumer stream). Mirrors handleInferenceError's cancelTerminal
// semantics: partial_success, NOT AdmittedButFailed — it must never pollute
// provider_error calibration signals.
const errorClassConsumerCancelAfterCommit = "consumer_cancel_after_commit"

// isConsumerCancelTerminal reports whether a provider terminal was caused by
// the CONSUMER (or by the coordinator acting on the consumer's behalf) rather
// than by the provider: a 499 status, or a "request cancelled" error message
// (the provider's response to a Cancel we sent). This is the single matcher
// shared by handleInferenceError's reputation carve-out and the route-outcome
// classification, so the two can never drift.
func isConsumerCancelTerminal(statusCode int, errMsg string) bool {
	return statusCode == statusClientClosedRequest ||
		strings.Contains(strings.ToLower(errMsg), "request cancelled")
}

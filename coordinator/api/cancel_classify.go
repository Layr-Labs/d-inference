package api

import "strings"

// Structured cancellation telemetry (DAR-346).
//
// These helpers project the coordinator's already-computed final_status /
// error_class into queryable dimensions — cancel_phase, cancel_source, and
// partial_settlement_status — without touching every cancel call site. They
// follow the same "derive centrally off the class string" pattern as
// inferenceErrorReason (route_outcome.go). Every value is a normalized enum;
// none carries prompt or response content.
//
// They populate ONLY genuine cancellation outcomes (a downstream client
// disconnect or a speculative-race loser). Provider failures and successes get
// empty values so the merge-on-nonzero bridge leaves them untouched.

// cancel_phase values.
const (
	cancelPhaseBeforeFirstToken      = "before_first_token"
	cancelPhaseAfterFirstToken       = "after_first_token"
	cancelPhaseAfterProviderComplete = "after_provider_complete"
	cancelPhaseSpeculativeLoser      = "speculative_loser"
)

// cancel_source values.
const (
	cancelSourceClientClosed       = "client_closed"
	cancelSourceCoordinatorTimeout = "coordinator_timeout"
	cancelSourceStreamIdleTimeout  = "stream_idle_timeout"
	cancelSourceTotalTimeout       = "total_timeout"
	cancelSourceProviderDisconnect = "provider_disconnect"
	cancelSourceProviderError      = "provider_error"
	cancelSourceSpeculativeLoser   = "speculative_loser"
	cancelSourceUnknown            = "unknown"
)

// partial_settlement_status values.
const (
	partialSettlementNone          = "none"
	partialSettlementSettled       = "settled"
	partialSettlementRefunded      = "refunded"
	partialSettlementExpired       = "expired"
	partialSettlementZeroDelivered = "zero_delivered"
)

// streamIdleGapThresholdMs is the measured no-progress gap above which an
// after-first-token client disconnect is reclassified from client_closed to
// stream_idle_timeout: a gap this large means the provider stalled mid-stream,
// which is the likely trigger for the downstream idle-timeout close. Heuristic.
const streamIdleGapThresholdMs = 15000

// isCancelClass reports whether an error_class denotes a request cancellation
// (downstream client disconnect or speculative-race loser) rather than a
// provider failure or a clean success. Only cancellation classes carry the
// cancel_phase / cancel_source / partial_settlement_status dimensions.
func isCancelClass(class string) bool {
	switch class {
	case "speculative_loser", "client_gone", "client_gone_before_response", "no_terminal_after_cancel":
		return true
	}
	return strings.HasPrefix(class, "client_gone_after_commit")
}

// deriveCancelPhase maps the error_class onto the lifecycle phase at which the
// cancellation landed.
func deriveCancelPhase(status, class string) string {
	if !isCancelClass(class) {
		return ""
	}
	switch {
	case class == "speculative_loser":
		return cancelPhaseSpeculativeLoser
	case class == errorClassClientGoneAfterCommitCompleted:
		return cancelPhaseAfterProviderComplete
	case class == "no_terminal_after_cancel", strings.HasPrefix(class, "client_gone_after_commit"):
		return cancelPhaseAfterFirstToken
	case class == "client_gone", class == "client_gone_before_response":
		return cancelPhaseBeforeFirstToken
	default:
		return ""
	}
}

// deriveCancelSource maps the error_class onto what the coordinator can observe
// about who/what caused the cancel. A genuine downstream disconnect is reported
// as client_closed: from a single TCP close the coordinator cannot natively
// separate user-abort from OpenRouter total/idle timeout. Phase 1 refines this
// to stream_idle_timeout when a measured no-progress gap preceded the close.
func deriveCancelSource(status, class string, code int) string {
	if !isCancelClass(class) {
		return ""
	}
	switch {
	case class == "speculative_loser":
		return cancelSourceSpeculativeLoser
	case strings.Contains(class, "provider_disconnect"):
		return cancelSourceProviderDisconnect
	case strings.Contains(class, "provider_error"):
		return cancelSourceProviderError
	default:
		return cancelSourceClientClosed
	}
}

// refineCancelSourceForIdle upgrades a generic client_closed cancel to
// stream_idle_timeout when a measured no-progress gap preceded the close: an
// after-first-token disconnect where the provider had stalled past the idle
// threshold. Other sources (provider_*, speculative_loser, coordinator timeouts)
// are returned unchanged — they already encode a more specific cause.
func refineCancelSourceForIdle(source, phase string, maxIdleGapMs float64) string {
	if source == cancelSourceClientClosed && phase == cancelPhaseAfterFirstToken && maxIdleGapMs >= streamIdleGapThresholdMs {
		return cancelSourceStreamIdleTimeout
	}
	return source
}

// deriveCancelSettlement maps the error_class onto how the cancelled request's
// reservation was resolved. settled = provider delivered and was paid; refunded
// = provider failed/acked-cancel with nothing further to bill; expired = no
// provider terminal arrived within the settlement grace; zero_delivered = the
// cancel landed before any content; none = a speculative-race loser (no
// settlement concept applies).
func deriveCancelSettlement(status, class string) string {
	switch {
	case class == "speculative_loser":
		return partialSettlementNone
	case class == errorClassClientGoneAfterCommitCompleted:
		return partialSettlementSettled
	case class == "no_terminal_after_cancel":
		return partialSettlementExpired
	case class == "client_gone", class == "client_gone_before_response":
		return partialSettlementZeroDelivered
	case strings.HasPrefix(class, "client_gone_after_commit"):
		return partialSettlementRefunded
	default:
		return ""
	}
}

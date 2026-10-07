package metrics

import (
	"strings"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// attempt_outcome classes. A fixed vocabulary: anything the mapping does not
// recognise lands in `other` rather than minting a new tag value.
const (
	AttemptSuccess             = "success"
	AttemptFirstChunkTimeout   = "first_chunk_timeout"
	AttemptDeadlineUnreachable = "deadline_unreachable"
	AttemptCapacity            = "capacity"
	AttemptClientError         = "client_error"
	AttemptFault               = "fault"
	AttemptSendFailed          = "send_failed"
	AttemptDisconnect          = "disconnect"
	AttemptClientGone          = "client_gone"
	AttemptSpeculativeLoser    = "speculative_loser"
	AttemptOther               = "other"
)

// queue_outcome classes: the queue-wait exits that never dispatched an attempt
// (dispatchState.queuedExitOutcome), keyed by the error_class those exits
// persist. A fixed vocabulary: anything else lands in `other`.
const (
	QueueClientGone            = "client_gone"
	QueueDeadline              = "queue_deadline"
	QueueTimeout               = "queue_timeout"
	QueueTTFTTooSlow           = "ttft_too_slow"
	QueueCapabilityUnsupported = "model_capability_unsupported"
	QueueOther                 = "other"
)

// orClassClientGone is the OR-view class for a client that left before the
// first token well inside the upstream budget (an application abort, not our
// slowness) and for post-commit client disconnects. EXCLUDED from the uptime
// formula, like rate_limited / client_error.
const ORClientGone = "client_gone"

// deadline_bucket tag values on routing.client_gone: elapsed time at the
// cancel relative to the request's first-content budget (d.deadline, the
// coordinator-side mirror of the upstream first-content deadline).
const (
	DeadlineUnderHalf     = "under_half"     // < 0.5 x budget: application abort
	DeadlineMid           = "mid"            // 0.5 .. 0.8 x budget
	DeadlineNear          = "near_deadline"  // >= 0.8 x budget: upstream was about to time out
	DeadlineOver          = "over"           // >= budget: upstream already timed out (its 504)
	DeadlineUnknown       = "unknown"        // no request clock on this dispatch
	DeadlineNotApplicable = "not_applicable" // after-commit phase: the budget was met
)

// isCapacityClassErrorReason reports whether a persisted error_reason names a
// capacity / admission condition (the provider is healthy but full, the
// request cannot fit, or the provider is draining ahead of a restart and
// refusing new work — routing counts that as transient capacity too) rather
// than a fault.
func isCapacityClassErrorReason(reason string) bool {
	switch failure.NormalizeReason(reason) {
	case failure.ErrorReasonCapacityBusy, failure.ErrorReasonCapacityTimeout, failure.ErrorReasonQueueFull,
		failure.ErrorReasonTokenBudgetExhaust, failure.ErrorReasonRequestExceedsContext,
		failure.ErrorReasonRequestExceedsNode, failure.ErrorReasonRequestExceedsNodeBudget,
		failure.ErrorReasonRequestExceedsBatchBudget, failure.ErrorReasonModelLoad,
		failure.ErrorReasonDraining, failure.ErrorReasonMediaMemoryUnavailable:
		return true
	default:
		return false
	}
}

// attemptOutcomeClass maps a TERMINAL route outcome to its attempt_outcome
// class. Returns "" for a non-terminal (commit-time pre-fill) outcome, which
// must not be counted. partial_success is an attempt that DID deliver first
// content (the ladder succeeded); its post-commit failure is measured on
// inference.in_band_error and request_outcome_or_view{mid_stream}, not here.
func AttemptOutcomeClass(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil {
		return ""
	}
	status := strings.ToLower(strings.TrimSpace(outcome.FinalStatus))
	class := strings.ToLower(strings.TrimSpace(outcome.ErrorClass))
	switch status {
	case "":
		return ""
	case "success", "partial_success":
		return AttemptSuccess
	case "cancelled":
		if class == "speculative_loser" {
			return AttemptSpeculativeLoser
		}
		return AttemptClientGone
	case "timeout":
		// Queue expiries never dispatched to a provider: they are fleet
		// capacity, not a first-content kill, and must not inflate the
		// per-model kill rate the alert sketch keys on.
		if class == "queue_timeout" || class == "queue_deadline" {
			return AttemptCapacity
		}
		return AttemptFirstChunkTimeout
	case "error":
		return attemptErrorOutcomeClass(class, outcome)
	default:
		return AttemptOther
	}
}

func attemptErrorOutcomeClass(class string, outcome *store.InferenceRouteOutcome) string {
	switch class {
	case "first_chunk_timeout":
		return AttemptFirstChunkTimeout
	case failure.ErrorReasonDeadlineUnreachable:
		return AttemptDeadlineUnreachable
	case failure.ErrorReasonClientError:
		return AttemptClientError
	case "provider_disconnect_pre_commit", "provider_disconnect_before_response":
		return AttemptDisconnect
	case "ttft_too_slow", "queue_timeout", failure.ErrorReasonQueueFull:
		return AttemptCapacity
	}
	if isCapacityClassErrorReason(outcome.ErrorReason) {
		return AttemptCapacity
	}
	switch class {
	case failure.ErrorReasonProviderError:
		// providerFailedRoutingOutcomeFor stamps AdmittedButFailed on every
		// provider-executed failure; a bare provider_error row without it is a
		// coordinator-side dispatch failure ("failed to send request to
		// provider", request preparation) — the attempt never reached the engine.
		if !outcome.AdmittedButFailed {
			return AttemptSendFailed
		}
		return AttemptFault
	case "provider_error_before_response", "provider_incomplete_before_response":
		return AttemptFault
	}
	return AttemptOther
}

// queueOutcomeClass maps the terminal outcome of a queue-wait exit (an
// outcome flagged QueueExit) to its queue_outcome class. Returns "" for a
// non-terminal outcome, which must not be counted.
func QueueOutcomeClass(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil || strings.TrimSpace(outcome.FinalStatus) == "" {
		return ""
	}
	switch class := strings.ToLower(strings.TrimSpace(outcome.ErrorClass)); class {
	case QueueClientGone, QueueDeadline, QueueTimeout,
		QueueTTFTTooSlow, QueueCapabilityUnsupported:
		return class
	default:
		return QueueOther
	}
}

// orViewClassForCommittedOutcome maps the terminal outcome of a COMMITTED
// attempt (the request delivered first content) to its OR-view class. ok is
// false for pre-content terminals, which are counted at the exhausted ladder /
// client-gone arms instead.
func ORViewClassForCommittedOutcome(outcome *store.InferenceRouteOutcome) (class string, ok bool) {
	if outcome == nil {
		return "", false
	}
	switch strings.ToLower(strings.TrimSpace(outcome.FinalStatus)) {
	case "success":
		return ORSuccess, true
	case "partial_success":
		errClass := strings.ToLower(strings.TrimSpace(outcome.ErrorClass))
		if strings.HasPrefix(errClass, "client_gone_after_commit") || errClass == "no_terminal_after_cancel" {
			// The consumer left after content had flowed: the upstream is the
			// one that hung up, so it is not graded against us.
			return ORClientGone, true
		}
		// provider_error/disconnect/incomplete_after_commit, stream_timeout_after_commit.
		return ORMidStream, true
	default:
		return "", false
	}
}

// deadlineBucket buckets a pre-content client cancel by how much of the
// first-content budget had elapsed when the client left.
func DeadlineBucket(elapsed, budget time.Duration) string {
	if budget <= 0 || elapsed < 0 {
		return DeadlineUnknown
	}
	ratio := float64(elapsed) / float64(budget)
	switch {
	case ratio < 0.5:
		return DeadlineUnderHalf
	case ratio < 0.8:
		return DeadlineMid
	case ratio < 1.0:
		return DeadlineNear
	default:
		return DeadlineOver
	}
}

// orViewClassForClientGone maps a pre-content client-gone deadline bucket to
// the OR-view class: at or past ~the upstream budget the upstream timed out on
// us (its 504 → timeout); earlier is an application abort (excluded).
func ORViewClassForClientGone(bucket string) string {
	switch bucket {
	case DeadlineNear, DeadlineOver:
		return ORTimeout
	default:
		return ORClientGone
	}
}

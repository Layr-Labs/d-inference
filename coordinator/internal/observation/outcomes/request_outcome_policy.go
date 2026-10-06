package outcomes

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// classifyRequestOutcome is analytics-only. It never feeds routing, status,
// retry, provider health, billing, or the existing uptime metrics.
func Classify(r *store.RequestOutcomeRecord) {
	r.ResponseProgress = "no_content_observed"
	if r.ProviderContentObserved {
		r.ResponseProgress = "content_observed"
	}
	if r.ProviderOutcome == "completed" {
		r.ResponseProgress = "provider_completed"
	}
	r.Termination = "unknown"
	if r.HandlerFinishedAt == nil {
		r.Termination = "in_progress"
		return
	}
	switch {
	case r.EvidenceConflict:
		r.Termination = "unknown"
	case r.ClientDeparted:
		r.Termination = "client_departure"
	case r.ClientWriteError || r.EgressError:
		r.Termination = "interrupted_response"
	case r.ProviderOutcome == "completed" && r.ResponseTerminal == "completed" && r.EgressCompleted && r.HTTPStatus >= 200 && r.HTTPStatus < 300:
		r.Termination = "completed"
	case r.HTTPStatus >= 400:
		r.Termination = "rejected"
	case r.RawReason == "handler_panic":
		r.Termination = "interrupted_response"
	case r.ProviderContentObserved || r.ContentWriteCompleted || r.ProviderOutcome == "error" || r.ResponseTerminal == "incomplete" || r.ResponseTerminal == "error":
		r.Termination = "interrupted_response"
	}
	r.NormalizedCode = NormalizedRequest(r.RawStage, r.RawReason, r.HTTPStatus, r.Termination)
	if r.Termination == "rejected" && r.CoordinatorExhausted && r.RawReason == "dispatch_exhausted" {
		r.NormalizedCode = "ext_coordinator_exhausted"
	}
}

func NormalizedAttempt(reason string) string {
	if reason == "deadline_unreachable" {
		return "int_provider_deadline_rejected"
	}
	if reason == "" {
		return ""
	}
	return "int_legacy:" + reason
}

func NormalizedRequest(stage, reason string, status int, termination string) string {
	if termination != "rejected" {
		return ""
	}
	if stage == "dispatch" && status == http.StatusTooManyRequests {
		switch reason {
		case "first_chunk_timeout":
			return "ext_first_content_timeout"
		case "deadline_unreachable":
			return "ext_coordinator_exhausted"
		}
	}
	// dispatch_exhausted alone is ambiguous (e.g. a retained real provider 504).
	// Preserve it as scoped raw diagnostics instead of hiding its precedence.
	if reason != "" {
		return "ext_legacy:" + reason
	}
	return "ext_unknown"
}

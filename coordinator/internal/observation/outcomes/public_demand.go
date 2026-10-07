package outcomes

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func PublicScope(consumer string, selfRouteOnly, preferOwner bool, allowedProviderSerials []string, publicModel, modelID string) *store.PublicDemandScope {
	if selfRouteOnly || preferOwner || len(allowedProviderSerials) != 0 || (consumer == "" || consumer == "admin") {
		return nil
	}
	model := publicModel
	if model == "" {
		model = modelID
	}
	if model == "" || len(model) > 256 {
		return nil
	}
	return &store.PublicDemandScope{Model: model, ConsumerHash: store.HashKey(consumer), Outcome: "unknown"}
}

// This is intentionally independent of HTTP status alone: a first-content
// timeout may be a 429, while a started 200 stream can still fail.
func PublicDemandOutcome(r store.RequestOutcomeRecord) string {
	if r.EvidenceConflict {
		return "unknown"
	}
	switch r.Termination {
	case "completed":
		return "completed"
	case "client_departure":
		return "cancelled"
	case "in_progress", "unknown":
		return "unknown"
	}
	if r.RawStage == "validation" || r.RawStage == "balance" || r.RawStage == "model_resolution" {
		return "excluded"
	}
	if r.RawStage == "preflight_capacity" && r.RawReason == "context_exceeded" {
		// The request exceeds the model's context window regardless of fleet capacity.
		return "excluded"
	}
	if r.RawStage == "dispatch" && r.RawReason == "dispatch_exhausted" &&
		r.CoordinatorExhausted && r.HTTPStatus == http.StatusTooManyRequests {
		// The terminal capacity probe found providers, but all were full. The
		// same raw reason also covers provider faults and genuine unavailability.
		return "capacity_rejected"
	}
	switch r.RawReason {
	case "first_chunk_timeout", "queue_timeout", "queue_deadline":
		return "timed_out"
	case "ttft_too_slow", "deadline_unreachable":
		return "latency_rejected"
	case "machine_busy", "capacity_exhausted", "routing_saturated", "no_provider", "queue_full", "unservable_token_budget", "prompt_too_long", "model_too_large":
		if r.HTTPStatus == http.StatusTooManyRequests || r.HTTPStatus == http.StatusServiceUnavailable {
			return "capacity_rejected"
		}
	}
	if r.HTTPStatus == http.StatusTooManyRequests {
		// Unknown 429s are not evidence of capacity pressure or a user quota.
		return "unknown"
	}
	if r.HTTPStatus >= 400 && r.HTTPStatus < 500 && r.HTTPStatus != 408 && r.HTTPStatus != 499 {
		return "excluded"
	}
	if r.HTTPStatus == 408 || r.HTTPStatus == 504 {
		return "timed_out"
	}
	if r.Termination == "interrupted_response" || r.HTTPStatus >= 500 {
		return "failed"
	}
	return "unknown"
}

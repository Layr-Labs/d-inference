package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Scope once, after account gates and body preparation, before any capacity
// rejection. Exclude owner-preferred and machine-restricted traffic as well as
// exclusive self-route; their demand is not interchangeable with public supply.
func markPublicModelDemand(r *http.Request, p inferenceAdmissionParams) {
	consumer := consumerKeyFromContext(r.Context())
	if p.policy.enabled || p.policy.prefer || len(p.allowedProviderSerials) != 0 || (consumer == "" || consumer == "admin") {
		return
	}
	model := p.publicModel
	if model == "" {
		model = p.model
	}
	if model == "" || len(model) > 256 {
		return
	}
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		defer o.mu.Unlock()
		o.record.PublicDemand = &store.PublicDemandScope{Model: model, ConsumerHash: store.HashKey(consumer), Outcome: "unknown"}
		o.publishLocked()
	}
}

// This is intentionally independent of HTTP status alone: a first-content
// timeout may be a 429, while a started 200 stream can still fail.
func publicDemandOutcome(r store.RequestOutcomeRecord) string {
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
	switch r.RawReason {
	case "first_chunk_timeout", "queue_timeout":
		return "timed_out"
	case "ttft_too_slow", "deadline_unreachable":
		return "latency_rejected"
	case "machine_busy", "capacity_exhausted", "routing_saturated", "no_provider":
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

package session

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func validLoadModelStatus(status string) bool {
	switch status {
	case protocol.LoadModelStatusStarted,
		protocol.LoadModelStatusSucceeded,
		protocol.LoadModelStatusFailed:
		return true
	default:
		return false
	}
}

func (s *Session) loadModelStatus(statusMsg *protocol.LoadModelStatusMessage) {
	if !validLoadModelStatus(statusMsg.Status) {
		// Both fields are provider-controlled until they pass the closed
		// status vocabulary and pending-command match below.
		s.deps.Logger().Warn("rejecting invalid load_model_status", "provider_id", s.providerID)
		s.deps.Telemetry.Incr("provider.load_model_status_rejected", []string{"reason:invalid_status"})
		return
	}
	if !s.deps.Registry().HasPendingModelLoad(s.providerID, statusMsg.ModelID) {
		s.deps.Logger().Warn("rejecting unsolicited load_model_status", "provider_id", s.providerID)
		s.deps.Telemetry.Incr("provider.load_model_status_rejected", []string{"reason:no_pending_command"})
		return
	}
	// The exact provider/model pair now names a live coordinator-issued
	// command, and Status is one of three fixed constants. Only canonical
	// values may cross into logs, metrics, or registry state.
	s.deps.Logger().Info("provider load_model_status",
		"provider_id", s.providerID,
		"model_id", statusMsg.ModelID,
		"status", statusMsg.Status,
	)
	switch statusMsg.Status {
	case protocol.LoadModelStatusSucceeded:
		// Mark the model warm on this provider BEFORE draining so
		// the scheduler sees it as a candidate. Without this, the
		// provider still looks cold until the next heartbeat.
		s.deps.Registry().MarkModelWarm(s.providerID, statusMsg.ModelID)
		duration := s.deps.Registry().ClearPendingModelLoad(s.providerID, statusMsg.ModelID)
		s.deps.Registry().RecordWarmPoolLoadResult(statusMsg.ModelID, true, duration)
		s.deps.Registry().DrainQueuedRequestsForModelWithReason(statusMsg.ModelID, registry.DrainTriggerLoad)
	case protocol.LoadModelStatusFailed:
		duration := s.deps.Registry().PendingModelLoadDuration(s.providerID, statusMsg.ModelID)
		s.deps.Registry().RecordWarmPoolLoadResult(statusMsg.ModelID, false, duration)
		// Quantify WHY proactive loads are rejected. The reason
		// is derived only from the existing error string (no new wire
		// field). The proactive path's string is often a generic
		// Foundation bridge ("other"), but dashboards still get the
		// draining vs descriptive classes, and the short backoff below
		// does NOT depend on this classification.
		reason := s.deps.LoadFailure.Classify(statusMsg.Error)
		s.deps.Telemetry.Incr("routing.load_model_rejects", []string{
			"model:" + statusMsg.ModelID,
			"reason:" + reason,
		})
		switch {
		case statusMsg.Error == protocol.ProviderDrainingForUpdate:
			// Transient: the provider refused only because it is
			// draining ahead of an auto-update restart. Shorten the
			// cooldown so a failed restart (provider resumes serving)
			// becomes loadable again quickly; queued requests are NOT
			// rejected — the provider is back within the queue window
			// and other providers remain plannable.
			s.deps.Registry().BackoffPendingModelLoadForDrain(s.providerID, statusMsg.ModelID)
			s.deps.Telemetry.Incr("routing.pending_load_backoff", []string{
				"model:" + statusMsg.ModelID, "kind:drain",
			})
		case s.deps.LoadFailure.Permanent(reason):
			// Permanent: the provider does not have this model, so a
			// fast retry just re-fails. Keep the full TTL cooldown set
			// when the load was planned (do NOT apply the short memory
			// backoff) so TriggerModelSwaps does not re-attempt the
			// unservable load every ~30s within the 120s queue window.
			// Still reject queued waiters that nothing can serve.
			s.deps.Registry().RejectUnservableQueuedRequests(statusMsg.ModelID)
		default:
			// A non-draining, non-permanent load failure is dominated by
			// transient memory pressure that frees in seconds. Re-stamp
			// the pending entry to the short memory backoff (~30s)
			// instead of leaving the full 2-min TTL — that window ≈ the
			// 120s queue timeout, so a request queued right after the
			// failure would time out before this provider (whose memory
			// may already have freed) is reconsidered by
			// TriggerModelSwaps. The ~10s warm-pool sweep reaps the short
			// entry deterministically.
			s.deps.Registry().BackoffPendingModelLoadForMemory(s.providerID, statusMsg.ModelID)
			s.deps.Telemetry.Incr("routing.pending_load_backoff", []string{
				"model:" + statusMsg.ModelID, "kind:memory",
			})
			// If no other provider can serve this model, reject queued
			// requests immediately rather than making them wait 120s.
			s.deps.Registry().RejectUnservableQueuedRequests(statusMsg.ModelID)
		}
	}
	// "started" status: no action — load is in progress.
}

// modelsUpdate merges a provider's authoritative model inventory update
// (sent after a verified prefetch) into its advertised models in place. Each
// build's weight hash is cross-checked against the catalog before it becomes
// routable, so a bad/buggy prefetch never takes traffic. This closes the loop
// without waiting for the provider to reconnect or resetting trust/reputation.
func (s *Session) modelsUpdate(providerID string, provider *registry.Provider, msg *protocol.ModelsUpdateMessage) {
	merged, dropped := s.deps.Registry().MergeProviderModelsWithCapabilities(
		providerID,
		msg.Models,
		msg.ToolConstraintProtocol,
		msg.ToolConstraintModels,
	)
	for _, id := range merged {
		s.deps.Logger().Info("provider now advertises build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Release any requests queued for this build now that a provider can
		// (cold-)serve it.
		s.deps.Registry().DrainQueuedRequestsForModel(id)
	}
	for _, id := range dropped {
		s.deps.Logger().Info("provider stopped advertising build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Requests may have queued against the concrete previous build while it
		// was still acceptable. Recheck immediately: drain to another provider if
		// one exists, otherwise fail fast instead of waiting for queue timeout.
		s.deps.Registry().DrainQueuedRequestsForModel(id)
		s.deps.Registry().RejectUnservableQueuedRequests(id)
	}
}

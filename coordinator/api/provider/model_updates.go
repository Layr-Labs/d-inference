package provider

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// handleModelsUpdate merges a provider's authoritative model inventory update
// (sent after a verified prefetch) into its advertised models in place. Each
// build's weight hash is cross-checked against the catalog before it becomes
// routable, so a bad/buggy prefetch never takes traffic. This closes the loop
// without waiting for the provider to reconnect or resetting trust/reputation.
func (s *Owner) handleModelsUpdate(providerID string, provider *registry.Provider, msg *protocol.ModelsUpdateMessage) {
	merged, dropped := s.registry.MergeProviderModelsWithCapabilities(
		providerID,
		msg.Models,
		msg.ToolConstraintProtocol,
		msg.ToolConstraintModels,
	)
	for _, id := range merged {
		s.logger.Info("provider now advertises build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Release any requests queued for this build now that a provider can
		// (cold-)serve it.
		s.registry.DrainQueuedRequestsForModel(id)
	}
	for _, id := range dropped {
		s.logger.Info("provider stopped advertising build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Requests may have queued against the concrete previous build while it
		// was still acceptable. Recheck immediately: drain to another provider if
		// one exists, otherwise fail fast instead of waiting for queue timeout.
		s.registry.DrainQueuedRequestsForModel(id)
		s.registry.RejectUnservableQueuedRequests(id)
	}
}

// attachProviderLocation resolves the provider's approximate geographic
// location from the registration HTTP request. The resolved location is
// stored on the Provider struct for stats aggregation. Raw IP addresses
// are never persisted.
func (s *Owner) attachProviderLocation(providerID string, provider *registry.Provider, r *http.Request) {
	if s.geoResolver == nil || provider == nil || r == nil {
		return
	}
	loc := s.geoResolver.Lookup(r)
	if loc == nil {
		return
	}
	provider.Mu().Lock()
	provider.Location = loc
	provider.Mu().Unlock()
	s.registry.PersistProvider(provider)
	// The stats:v1 read-cache entry is owned by the stats refresher (stats.go)
	// and is NOT evicted here. Evicting it on every registration (~1,400/hour
	// in production) turned its 60 s TTL into ~2.6 s and made every /v1/stats
	// request rerun the multi-second usage analytics statements.
	s.logger.Info("provider location resolved",
		"provider_id", providerID,
		"city", loc.City,
		"country", loc.CountryCode,
		"source", loc.Source,
	)
}

// challengeLoop periodically sends attestation challenges to a provider.

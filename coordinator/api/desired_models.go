package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// fanOutDesiredModels pushes the current desired_models to every connected
// provider that should learn it. It is gated per provider: only Swift-runtime
// providers at/above minProviderVersionForDesiredModels receive the message,
// because a pre-feature provider's strict decoder throws on unknown types.
// IDs+entries are collected under the registry's read lock and the sends happen
// afterward (SendDesiredModels takes the lock again).
func (s *Server) fanOutDesiredModels() {
	// Collect eligible provider IDs under the registry read lock, then compute
	// entries and send AFTER releasing it. DesiredModelsForProvider and
	// SendDesiredModels each take r.mu themselves, so calling them inside the
	// ForEachProvider callback (which already holds r.mu.RLock) would nest the
	// read lock — a deadlock once a writer queues between the outer and inner
	// RLock (Go's RWMutex blocks new readers while a writer waits).
	var eligibleIDs []string
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		id, backend, version := p.ID, p.Backend, p.Version
		p.Mu().Unlock()
		if s.providerSupportsDesiredModels(backend, version) {
			eligibleIDs = append(eligibleIDs, id)
		}
	})
	for _, id := range eligibleIDs {
		// Empty entry sets are sent too: "nothing is desired" is meaningful
		// state — it marks a provider's in-flight prefetch for a now-deleted/
		// repointed alias as stale (see SendDesiredModels).
		if err := s.registry.SendDesiredModels(id, s.registry.DesiredModelsForProvider(id)); err != nil {
			s.logger.Warn("failed to push desired_models", "provider_id", id, "error", err)
		}
	}
}

// providerSupportsDesiredModels reports whether a provider can receive the
// desired_models message: it must run the Swift backend and report a version at
// or above minProviderVersionForDesiredModels. A provider that reports no version
// is treated as too old (fail-closed).
func (s *Server) providerSupportsDesiredModels(backend, version string) bool {
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false
	}
	if version == "" {
		return false
	}
	return !semverLess(version, minProviderVersionForDesiredModels)
}

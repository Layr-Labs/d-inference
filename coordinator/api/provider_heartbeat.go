package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Reordered sequence-stamped heartbeats still prove liveness, but must not
// contribute repeated samples from the unchanged allocator snapshot.
func (s *Server) applyProviderHeartbeat(id string, provider *registry.Provider, msg *protocol.HeartbeatMessage) bool {
	previous := provider.BackendCapacitySnapshot()
	if !s.registry.Heartbeat(id, msg) {
		return false
	}
	capacity := provider.BackendCapacitySnapshot()
	s.recordBackendWedgeTelemetry(capacity)
	s.recordMLXCacheTelemetry(provider, previous, capacity)
	return true
}

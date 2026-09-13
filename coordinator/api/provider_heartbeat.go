package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Older snapshots remain visible with age but emit no current-value samples.
// This shared telemetry limit is observational, never a routing gate.
const capacitySampleFreshMS = 5 * 60 * 1000

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
	s.recordPrefixCacheTelemetry(provider, previous, capacity)
	s.recordPagedStorageTelemetry(provider, previous, capacity)
	s.recordProcessMemoryTelemetry(provider, previous, capacity)
	return true
}

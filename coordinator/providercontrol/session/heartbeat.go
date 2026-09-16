package session

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Session) heartbeat(hbMsg *protocol.HeartbeatMessage) {
	replaceCacheCapabilities :=
		hbMsg.PrefixCacheProtocol != 0 || hbMsg.PrefixCacheV2Models != nil
	if replaceCacheCapabilities ||
		hbMsg.PrefixCacheMemoryModels != nil ||
		hbMsg.PrefixCacheStatuses != nil ||
		hbMsg.PrefixCacheDonationOutcomes != nil {
		var capabilities []protocol.PrefixCacheV2Capability
		if hbMsg.PrefixCacheV2Models != nil {
			capabilities = *hbMsg.PrefixCacheV2Models
		}
		_, err := s.deps.Registry().UpdatePrefixCacheSnapshot(
			s.providerID,
			replaceCacheCapabilities,
			hbMsg.PrefixCacheProtocol,
			capabilities,
			hbMsg.PrefixCacheMemoryModels,
			hbMsg.PrefixCacheStatuses,
			hbMsg.PrefixCacheDonationOutcomes,
		)
		if err != nil && (replaceCacheCapabilities || hbMsg.PrefixCacheMemoryModels != nil) {
			s.deps.Logger().Warn("rejecting malformed heartbeat cache capabilities",
				"provider_id", s.providerID)
			s.deps.Telemetry.Incr("routing.cache_capability_rejected", []string{"source:heartbeat"})
			// Malformed refreshes cannot leave stale v2 evidence live.
			_, _ = s.deps.Registry().UpdatePrefixCacheSnapshot(
				s.providerID,
				true,
				1,
				nil,
				nil,
				hbMsg.PrefixCacheStatuses,
				hbMsg.PrefixCacheDonationOutcomes,
			)
		} else if err != nil {
			s.deps.Logger().Warn("failed to apply heartbeat cache telemetry",
				"provider_id", s.providerID)
			s.deps.Telemetry.Incr("routing.cache_telemetry_rejected", []string{"source:heartbeat"})
		}
	}
	s.ApplyHeartbeat(s.providerID, s.provider, hbMsg)
	// A late or changed APNs token carried in the heartbeat
	// re-arms a code-identity challenge WITHOUT a reconnect.
	s.deps.CodeRearm(s.loopCtx, s.providerID, s.provider, hbMsg)
}

// Reordered sequence-stamped heartbeats still prove liveness, but must not
// contribute repeated samples from the unchanged allocator snapshot.
func (s *Session) ApplyHeartbeat(id string, provider *registry.Provider, msg *protocol.HeartbeatMessage) bool {
	previous := provider.BackendCapacitySnapshot()
	if !s.deps.Registry().Heartbeat(id, msg) {
		return false
	}
	capacity := provider.BackendCapacitySnapshot()
	s.deps.Telemetry.Heartbeat.BackendWedge(capacity)
	s.deps.Telemetry.Heartbeat.MLXCache(provider, previous, capacity)
	s.deps.Telemetry.Heartbeat.PrefixCache(provider, previous, capacity)
	s.deps.Telemetry.Heartbeat.PagedStorage(provider, previous, capacity)
	s.deps.Telemetry.Heartbeat.ProcessMemory(provider, previous, capacity)
	return true
}

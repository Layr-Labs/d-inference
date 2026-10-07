package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// BeginNativePair is an explicit in-process coordinator selection hook. There
// is deliberately no provider request or public HTTP route that can choose a
// peer, approve a runtime, or manufacture this authorization. The later cluster
// scheduler must supply its selected exact connections after caller policy.
func (s *Server) BeginNativePair(members [2]*registry.Provider, approvalID string, lifetime time.Duration) (*registry.NativePairSession, error) {
	if s.nativePairs == nil {
		return nil, registry.ErrNativePairApproval
	}
	connections, e := s.nativePairs.Connections(members)
	if e != nil {
		return nil, e
	}
	return s.nativePairs.Reserve(connections, approvalID, lifetime)
}

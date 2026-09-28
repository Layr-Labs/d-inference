package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Only the pair selector may pass pairEligibility. Its complete hardware,
// release, process-key, freshness and bilateral ownership gates still follow.
func (p *Provider) executionRolePermitsLocked(pairEligibility bool) bool {
	switch p.executionRole {
	case protocol.ExecutionRoleSolo:
		return true
	case protocol.ExecutionRoleClusterMember:
		return pairEligibility
	default:
		return false
	}
}

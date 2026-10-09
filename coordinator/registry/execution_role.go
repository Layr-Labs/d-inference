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

// ClusterMemberAcceptance is the acknowledgement owed to a connection this
// registry holds in the control-only member role: its own registered nonce and
// connection ID, never a value a later frame supplies. ok is false for solo.
// Both fields are immutable for the connection, so no lock is taken.
func (p *Provider) ClusterMemberAcceptance() (protocol.ClusterMemberAcceptedMessage, bool) {
	if p == nil || p.executionRole != protocol.ExecutionRoleClusterMember {
		return protocol.ClusterMemberAcceptedMessage{}, false
	}
	return protocol.ClusterMemberAcceptedMessage{
		Type:                    protocol.TypeClusterMemberAccepted,
		ExecutionRole:           p.executionRole,
		MemberRegistrationNonce: p.memberNonce,
		ProviderID:              p.ID,
	}, true
}

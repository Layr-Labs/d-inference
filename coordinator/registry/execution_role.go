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

// ExecutionRole is the role this connection registered in. Immutable.
func (p *Provider) ExecutionRole() protocol.ExecutionRole {
	if p == nil {
		return ""
	}
	return p.executionRole
}

// ClusterMembership is the cluster this member connection registered, if it
// registered one. Immutable; the returned value is a copy.
func (p *Provider) ClusterMembership() (protocol.ClusterMembership, bool) {
	if p == nil || p.clusterMembership == nil {
		return protocol.ClusterMembership{}, false
	}
	return *p.clusterMembership, true
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

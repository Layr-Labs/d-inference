package protocol

import "fmt"

// ExecutionRole restricts a connection. It grants no trust or model capability.
// Empty is the legacy solo wire representation; role is immutable until disconnect.
type ExecutionRole string

const (
	ExecutionRoleSolo          ExecutionRole = ""
	ExecutionRoleClusterMember ExecutionRole = "cluster_member"
	TypeClusterMemberAccepted                = "cluster_member_accepted"
)

func (m *RegisterMessage) ValidateExecutionRole() error {
	switch m.ExecutionRole {
	case ExecutionRoleSolo:
		if m.MemberRegistrationNonce != "" || len(m.ClusterModels) != 0 {
			return fmt.Errorf("protocol: member fields require member role")
		}
	case ExecutionRoleClusterMember:
		// Old coordinators see an empty ordinary inventory and cannot cold-route it.
		if len(m.Models) != 0 || len(m.MemberRegistrationNonce) != 64 {
			return fmt.Errorf("protocol: invalid member registration")
		}
		for _, c := range m.MemberRegistrationNonce {
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return fmt.Errorf("protocol: invalid member nonce")
			}
		}
	default:
		return fmt.Errorf("protocol: unsupported execution role")
	}
	return nil
}

// Confirms protocol support and the exact WebSocket registration only. It does
// not attest hardware, authorize owners, issue a key, or promise readiness.
type ClusterMemberAcceptedMessage struct {
	Type                    string        `json:"type"`
	ExecutionRole           ExecutionRole `json:"execution_role"`
	MemberRegistrationNonce string        `json:"member_registration_nonce"`
	ProviderID              string        `json:"provider_id"`
}

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
		if m.MemberRegistrationNonce != "" || len(m.ClusterModels) != 0 || m.ClusterMembership != nil {
			return fmt.Errorf("protocol: member fields require member role")
		}
	case ExecutionRoleClusterMember:
		// Old coordinators see an empty ordinary inventory and cannot cold-route it.
		if len(m.Models) != 0 || len(m.MemberRegistrationNonce) != 64 {
			return fmt.Errorf("protocol: invalid member registration")
		}
		if !lowerHex(m.MemberRegistrationNonce) {
			return fmt.Errorf("protocol: invalid member nonce")
		}
		if m.ClusterMembership != nil {
			return m.ClusterMembership.Validate()
		}
	default:
		return fmt.Errorf("protocol: unsupported execution role")
	}
	return nil
}

// ClusterMembership is a member's saved cluster configuration as it registers
// it: which cluster it belongs to, its fixed rank there, and the coordinator
// runtime policy it installed. It is a claim the coordinator matches against a
// second member and its own approval catalog; it grants nothing by itself. A
// member that omits it is acknowledged but never selected into a pair.
type ClusterMembership struct {
	// ClusterID is the saved cluster label both members share.
	ClusterID string `json:"cluster_id"`
	// Rank is the member's fixed rank: 0 owns requests (leader), 1 is the follower.
	Rank int `json:"rank"`
	// PolicySHA256 is the lowercase hex SHA-256 of the canonical coordinator
	// runtime policy this member installed and will require in a prepare frame.
	PolicySHA256 string `json:"policy_sha256"`
}

const clusterLabelLimit = 128

func (c *ClusterMembership) Validate() error {
	if !clusterLabel(c.ClusterID) || (c.Rank != 0 && c.Rank != 1) ||
		len(c.PolicySHA256) != 64 || !lowerHex(c.PolicySHA256) {
		return fmt.Errorf("protocol: invalid cluster membership")
	}
	return nil
}

// clusterLabel mirrors the provider's saved-configuration label syntax
// (ClusterConfigurationSyntax.label): ASCII letters, digits, '-', '.', '_'.
func clusterLabel(value string) bool {
	if value == "" || len(value) > clusterLabelLimit || value[0] == '-' {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if !(c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c == '-' || c == '.' || c == '_') {
			return false
		}
	}
	return true
}

func lowerHex(value string) bool {
	for i := 0; i < len(value); i++ {
		if c := value[i]; !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Confirms protocol support and the exact WebSocket registration only. It does
// not attest hardware, authorize owners, issue a key, or promise readiness.
type ClusterMemberAcceptedMessage struct {
	Type                    string        `json:"type"`
	ExecutionRole           ExecutionRole `json:"execution_role"`
	MemberRegistrationNonce string        `json:"member_registration_nonce"`
	ProviderID              string        `json:"provider_id"`
}

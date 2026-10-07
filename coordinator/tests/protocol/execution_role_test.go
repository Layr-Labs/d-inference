package protocol_test

// Mirrored from the research branch's in-package test; adapted to the
// repository rule that coordinator tests live under coordinator/tests/.

import (
	"encoding/json"
	production "github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
)

func TestMemberRoleLegacyOmissionAndClosedValidation(t *testing.T) {
	base := production.RegisterMessage{Type: production.TypeRegister, Models: []production.ModelInfo{}}
	encoded, err := json.Marshal(base)
	if err != nil || strings.Contains(string(encoded), "execution_role") || strings.Contains(string(encoded), "cluster_models") {
		t.Fatal("legacy role fields emitted", err)
	}
	for _, raw := range []string{
		`{"type":"register","models":[],"execution_role":"bogus"}`,
		`{"type":"register","models":[],"cluster_models":[{"id":"x"}]}`,
		`{"type":"register","models":[],"member_registration_nonce":"` + strings.Repeat("a", 64) + `"}`,
		`{"type":"register","models":[],"execution_role":"cluster_member","member_registration_nonce":"short"}`,
		`{"type":"register","models":[{"id":"x"}],"execution_role":"cluster_member","member_registration_nonce":"` + strings.Repeat("a", 64) + `"}`,
	} {
		var decoded production.ProviderMessage
		if err := production.DecodeProviderMessage([]byte(raw), &decoded); err == nil {
			t.Fatal("invalid role accepted", raw)
		}
	}
	base.ExecutionRole = production.ExecutionRoleClusterMember
	base.MemberRegistrationNonce = strings.Repeat("a", 64)
	base.ClusterModels = []production.ModelInfo{{ID: "cluster-model"}}
	encoded, err = json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	var decoded production.ProviderMessage
	if err := production.DecodeProviderMessage(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	m := decoded.Payload.(*production.RegisterMessage)
	if len(m.Models) != 0 || len(m.ClusterModels) != 1 || m.ExecutionRole != production.ExecutionRoleClusterMember {
		t.Fatal("role inventory lost")
	}
	// An old decoder sees NO routable model even though it ignores added fields.
	var old struct {
		Models []production.ModelInfo `json:"models"`
	}
	if err := json.Unmarshal(encoded, &old); err != nil || len(old.Models) != 0 {
		t.Fatal("old server gets solo inventory", err)
	}
}

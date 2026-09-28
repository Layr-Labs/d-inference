package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMemberRoleLegacyOmissionAndClosedValidation(t *testing.T) {
	base := RegisterMessage{Type: TypeRegister, Models: []ModelInfo{}}
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
		var decoded ProviderMessage
		if err := DecodeProviderMessage([]byte(raw), &decoded); err == nil {
			t.Fatal("invalid role accepted", raw)
		}
	}
	base.ExecutionRole = ExecutionRoleClusterMember
	base.MemberRegistrationNonce = strings.Repeat("a", 64)
	base.ClusterModels = []ModelInfo{{ID: "cluster-model"}}
	encoded, err = json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ProviderMessage
	if err := DecodeProviderMessage(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	m := decoded.Payload.(*RegisterMessage)
	if len(m.Models) != 0 || len(m.ClusterModels) != 1 || m.ExecutionRole != ExecutionRoleClusterMember {
		t.Fatal("role inventory lost")
	}
	// An old decoder sees NO routable model even though it ignores added fields.
	var old struct {
		Models []ModelInfo `json:"models"`
	}
	if err := json.Unmarshal(encoded, &old); err != nil || len(old.Models) != 0 {
		t.Fatal("old server gets solo inventory", err)
	}
}

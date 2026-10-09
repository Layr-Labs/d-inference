package protocol_test

// A member registers the saved cluster configuration the coordinator pairs it
// by: cluster label, fixed rank and the coordinator policy it installed. The
// field is additive, member-only and closed: a solo registration that carries
// it, or a malformed one, never reaches the registry.

import (
	"encoding/json"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func memberRegisterJSON(membership string) string {
	frame := `{"type":"register","models":[],"execution_role":"cluster_member","member_registration_nonce":"` +
		strings.Repeat("a", 64) + `","cluster_models":[{"id":"cluster-model"}]`
	if membership != "" {
		frame += `,"cluster_membership":` + membership
	}
	return frame + `}`
}

func TestClusterMembershipRegistrationIsOptionalAndClosed(t *testing.T) {
	policy := strings.Repeat("b", 64)
	valid := `{"cluster_id":"studio-pair.1_a","rank":1,"policy_sha256":"` + policy + `"}`

	var decoded production.ProviderMessage
	if err := production.DecodeProviderMessage([]byte(memberRegisterJSON(valid)), &decoded); err != nil {
		t.Fatalf("valid member membership refused: %v", err)
	}
	got := decoded.Payload.(*production.RegisterMessage).ClusterMembership
	if got == nil || got.ClusterID != "studio-pair.1_a" || got.Rank != 1 || got.PolicySHA256 != policy {
		t.Fatalf("membership lost in decode: %+v", got)
	}

	// Today's member omits it and stays valid; its wire bytes are unchanged.
	if err := production.DecodeProviderMessage([]byte(memberRegisterJSON("")), &decoded); err != nil {
		t.Fatalf("member without membership refused: %v", err)
	}
	if decoded.Payload.(*production.RegisterMessage).ClusterMembership != nil {
		t.Fatal("membership invented for a member that registered none")
	}
	encoded, err := json.Marshal(production.RegisterMessage{Type: production.TypeRegister, Models: []production.ModelInfo{}})
	if err != nil || strings.Contains(string(encoded), "cluster_membership") {
		t.Fatal("membership emitted for an ordinary registration", err)
	}

	refused := map[string]string{
		"solo carries membership": `{"type":"register","models":[],"cluster_membership":` + valid + `}`,
		"empty cluster label":     memberRegisterJSON(`{"cluster_id":"","rank":0,"policy_sha256":"` + policy + `"}`),
		"leading dash":            memberRegisterJSON(`{"cluster_id":"-pair","rank":0,"policy_sha256":"` + policy + `"}`),
		"label with a space":      memberRegisterJSON(`{"cluster_id":"my pair","rank":0,"policy_sha256":"` + policy + `"}`),
		"label too long":          memberRegisterJSON(`{"cluster_id":"` + strings.Repeat("c", 129) + `","rank":0,"policy_sha256":"` + policy + `"}`),
		"third rank":              memberRegisterJSON(`{"cluster_id":"pair","rank":2,"policy_sha256":"` + policy + `"}`),
		"negative rank":           memberRegisterJSON(`{"cluster_id":"pair","rank":-1,"policy_sha256":"` + policy + `"}`),
		"short policy digest":     memberRegisterJSON(`{"cluster_id":"pair","rank":0,"policy_sha256":"abc"}`),
		"uppercase policy digest": memberRegisterJSON(`{"cluster_id":"pair","rank":0,"policy_sha256":"` + strings.Repeat("B", 64) + `"}`),
		"missing policy digest":   memberRegisterJSON(`{"cluster_id":"pair","rank":0}`),
	}
	for name, raw := range refused {
		if err := production.DecodeProviderMessage([]byte(raw), &decoded); err == nil {
			t.Fatalf("%s: accepted %s", name, raw)
		}
	}
}

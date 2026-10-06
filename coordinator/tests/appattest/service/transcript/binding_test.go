package transcript_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAppAttestEnrollmentRecoveryUsesOriginalTranscriptAndOwner(t *testing.T) {
	st := memorystore.NewMemory(store.Config{})
	now := time.Now()
	keyID := "key"
	b := transcript.Binding{AppID: "TEST.app", Environment: "production", Owner: "owner", Account: "account", Session: "new", Challenge: "new challenge", PublicKey: "new endpoint", ProtocolVersion: 3, KeyID: &keyID}
	e := store.AppAttestEnrollment{ProtocolVersion: 3, ID: "original", Owner: "owner", KeyID: "key", CreatedAt: now, AppID: "TEST.app", Environment: "production", Challenge: "old challenge", PublicKey: "old endpoint", AccountScope: transcript.AccountScope(b.Account)}
	if err := st.SaveAppAttestEnrollment(context.Background(), e); err != nil {
		t.Fatal(err)
	}
	reply := protocol.AppAttestShadowPayload{ProtocolVersion: 3, EnrollmentSession: "original", Status: &protocol.AppAttestStatus{OSVersion: "27"}}
	hash, _, err := transcript.Prepare(context.Background(), st, b, "attest", reply)
	if err != nil || hash != protocol.AppAttestShadowHashV3("attest", e.ID, e.Environment, e.KeyID, e.Challenge, e.PublicKey, e.AccountScope, reply.Status) {
		t.Fatalf("recovery %v", err)
	}
	b.Owner = "attacker"
	if _, _, err = transcript.Prepare(context.Background(), st, b, "attest", reply); err == nil {
		t.Fatal("cross-owner recovery")
	}
}

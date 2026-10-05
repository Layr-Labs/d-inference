package exchange_test

import (
	"context"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type failingEnrollmentRead struct {
	*memorystore.MemoryStore
	reads  int
	record store.AppAttestEnrollment
}

func (s *failingEnrollmentRead) GetAppAttestEnrollment(context.Context, string) (*store.AppAttestEnrollment, error) {
	s.reads++
	if s.reads == 1 {
		return nil, errors.New("temporary database timeout")
	}
	return &s.record, nil
}

func TestAppAttestEnrollmentStoreFailureIsRetryableAndSnapshotReadOnce(t *testing.T) {
	st := &failingEnrollmentRead{MemoryStore: memorystore.NewMemory(store.Config{})}
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	credential := &store.AppAttestShadowKey{KeyID: "key"}
	x := exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{AppID: "TEST.app", Environment: "production", Session: "current", Owner: "owner", Account: "account", PublicKey: "endpoint", Challenge: "nonce", ProtocolVersion: 3, KeyID: &credential.KeyID},
		Expected: "attestation", Credential: credential}}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st}, Archive: st, Enrollments: st, Provider: &registry.Provider{ID: "session"},
		Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: integrity})
	st.record = store.AppAttestEnrollment{ProtocolVersion: 3, ID: "original", Owner: x.Challenge.Binding.Owner, KeyID: "key", CreatedAt: time.Now(), AppID: "TEST.app", Environment: "production", Challenge: "original nonce", PublicKey: "original endpoint", AccountScope: transcript.AccountScope(x.Challenge.Binding.Account)}
	p := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.Challenge.Binding.Session, Challenge: x.Challenge.Binding.Challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: "original", Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
	result := pipeline.Handle(context.Background(), x, p)
	if next := result.Next; next != "stop" || result.Outcome != "enrollment_storage_error" || !recovery.RetryableOutcome(result.Outcome) {
		t.Fatalf("storage failure lost: %s %s", next, result.Outcome)
	}
	if st.reads != 1 {
		t.Fatalf("archive and verifier took different snapshots: %d reads", st.reads)
	}
	if _, _, err := transcript.Prepare(context.Background(), st, x.Challenge.Binding, "attest", p); err != nil {
		t.Fatal("later retry could not recover", err)
	}
}

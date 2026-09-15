package api

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type failingEnrollmentRead struct {
	*store.MemoryStore
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
	st := &failingEnrollmentRead{MemoryStore: store.NewMemory(store.Config{})}
	x := &appAttestShadowSession{s: &Server{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), appAttestShadow: AppAttestShadowConfig{AppID: "TEST.app", Environment: "production"}}, store: st, provider: &registry.Provider{ID: "session"}, id: "current", owner: "owner", account: "account", publicKey: "endpoint", challenge: "nonce", expected: "attestation", protocolVersion: 3, key: &store.AppAttestShadowKey{KeyID: "key"}}
	st.record = store.AppAttestEnrollment{ID: "original", Owner: x.owner, KeyID: "key", CreatedAt: time.Now(), AppID: "TEST.app", Environment: "production", Challenge: "original nonce", PublicKey: "original endpoint", AccountScope: x.accountScope()}
	p := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.id, Challenge: x.challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: "original", Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
	if next := x.handle(context.Background(), p); next != "stop" || x.lastOutcome != "enrollment_storage_error" || !retryableAppAttestOutcome(x.lastOutcome) {
		t.Fatalf("storage failure lost: %s %s", next, x.lastOutcome)
	}
	if st.reads != 1 {
		t.Fatalf("archive and verifier took different snapshots: %d reads", st.reads)
	}
	if _, err := x.clientHash(context.Background(), "attest", p); err != nil {
		t.Fatal("later retry could not recover", err)
	}
}

package exchange_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/input"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
)

func newSessionProvider(endpoint, signingKey string) *registry.Provider {
	return &registry.Provider{ID: "p1", PublicKey: endpoint, APNsDeviceToken: "devtok", APNsEnvironment: "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: signingKey}}
}

type failedEvidenceArchive struct{}

type capturedProofArchive struct{ evidence store.AppAttestEvidence }

func (s *capturedProofArchive) BeginAppAttestEvidence(_ context.Context, e store.AppAttestEvidence) error {
	s.evidence = e
	return nil
}
func (*capturedProofArchive) CompleteAppAttestEvidence(_ context.Context, _ string, d store.AppAttestDecision) (string, error) {
	return d.Outcome, nil
}

func (failedEvidenceArchive) BeginAppAttestEvidence(context.Context, store.AppAttestEvidence) error {
	return errors.New("offline")
}
func (failedEvidenceArchive) CompleteAppAttestEvidence(context.Context, string, store.AppAttestDecision) (string, error) {
	return "", errors.New("offline")
}

func TestAppAttestArchiveFailureDoesNotAdvanceCounter(t *testing.T) {
	st := memorystore.NewMemory(store.Config{})
	key := &store.AppAttestShadowKey{KeyID: "key", Owner: "owner"}
	_, _ = st.InsertAppAttestShadowKey(context.Background(), *key)
	p := newSessionProvider("endpoint", "se")
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st},
		Provider: p, Archive: failedEvidenceArchive{}, Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: integrity})
	x := exchange.Attempt{Challenge: exchange.Challenge{Credential: key, Expected: "assertion"}}
	before, _ := json.Marshal(p.GetTrustLevel())
	if got := pipeline.Handle(context.Background(), x, protocol.AppAttestShadowPayload{Action: "assertion", Proof: "invalid"}).Next; got != "stop" {
		t.Fatal(got)
	}
	after, _ := json.Marshal(p.GetTrustLevel())
	stored, _ := st.GetAppAttestShadowKey(context.Background(), "key")
	if string(before) != string(after) || stored.Counter != 0 {
		t.Fatal("archive failure mutated serving/key state")
	}
}

func TestQueuedAssertionCannotAbsorbLaterInboxDrop(t *testing.T) {
	ctx := context.Background()
	st := memorystore.NewMemory(store.Config{})
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := newSessionProvider(endpoint, "se")
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	record := store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", PublicKey: public, AppID: "TEST.app", Environment: "production"}
	if _, err := st.InsertAppAttestShadowKey(ctx, record); err != nil {
		t.Fatal(err)
	}
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st, Verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})},
		Provider: p, Archive: st, Enrollments: st, Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: integrity})
	x := exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{AppID: "TEST.app", Environment: "production", Session: "session", Owner: "owner", PublicKey: endpoint, ProtocolVersion: 3,
		Challenge: "challenge-a"}, Expected: "assertion", Credential: &record}}
	inbox := make(chan protocol.AppAttestShadowPayload, 1)
	admission := &input.Admission{}
	proof := func(counter byte) protocol.AppAttestShadowPayload {
		t.Helper()
		rp := sha256.Sum256([]byte("TEST.app"))
		auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, counter)
		status := &protocol.AppAttestStatus{OSVersion: "27"}
		hash := protocol.AppAttestShadowHashV3("assert", x.Challenge.Binding.Session, x.Challenge.Binding.Environment, record.KeyID, x.Challenge.Binding.Challenge, x.Challenge.Binding.PublicKey, transcript.AccountScope(x.Challenge.Binding.Account), status)
		signed := sha256.Sum256(append(auth, hash[:]...))
		signed = sha256.Sum256(signed[:])
		signature, err := ecdsa.SignASN1(rand.Reader, key, signed[:])
		if err != nil {
			t.Fatal(err)
		}
		body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
		if err != nil {
			t.Fatal(err)
		}
		return protocol.AppAttestShadowPayload{Session: x.Challenge.Binding.Session, Action: "assertion", Result: "ok", KeyID: record.KeyID,
			Challenge: x.Challenge.Binding.Challenge, Proof: base64.StdEncoding.EncodeToString(body), ProtocolVersion: 3, Status: status}
	}
	integrity.BeginChallenge()
	admission.Offer(proof(1), inbox, func() { integrity.Drop(nil, nil) })
	admission.Offer(proof(1), inbox, func() { integrity.Drop(nil, nil) })
	if integrity.Dropped() != 1 {
		t.Fatal("later inbox loss was not counted")
	}
	if next := pipeline.Handle(ctx, x, <-inbox).Next; next != "wait" {
		t.Fatalf("older assertion was not independently verified: %s", next)
	}
	if !integrity.Archived() || integrity.Complete() {
		t.Fatal("older archived proof absorbed a later unarchived input")
	}
	if v := appattest.EvaluateAuthorization(appattest.AuthorizationEvidence{ArchiveComplete: integrity.Complete()}, time.Now()); !slices.Contains(v.Reasons, "evidence_archive_gap") {
		t.Fatal("older proof escaped the archive policy gate")
	}
	x.Challenge.Binding.Challenge = "challenge-c"
	integrity.BeginChallenge()
	if next := pipeline.Handle(ctx, x, proof(2)).Next; next != "wait" || !integrity.Complete() {
		t.Fatalf("fresh archived assertion did not recover after the historical gap: %s", next)
	}
	stored, err := st.GetAppAttestShadowKey(ctx, record.KeyID)
	if err != nil || stored.Counter != 2 || integrity.Dropped() != 1 {
		t.Fatal("fresh counter or cumulative gap audit was lost")
	}
}

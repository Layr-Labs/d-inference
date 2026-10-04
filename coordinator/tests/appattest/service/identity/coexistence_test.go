package identity_test

import (
	"context"
	"testing"
	"time"

	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type capturedRecoveryArchive struct {
	*memorystore.MemoryStore
	evidence store.AppAttestEvidence
}

func (a *capturedRecoveryArchive) BeginAppAttestEvidence(ctx context.Context, e store.AppAttestEvidence) error {
	a.evidence = e
	return a.MemoryStore.BeginAppAttestEvidence(ctx, e)
}

func TestUnsignedChallengeMismatchCannotRevokeIndependentLegacyTrust(t *testing.T) {
	s, p, _, _ := newAuthorizationFixture(t)
	makeLegacyAuthorized(p)
	if !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("fixture lacks legacy authorization")
	}
	h := &rotationHarness{mem: s.store.(*statusReadinessStore).MemoryStore}
	x := h.exchange(3, p)
	x.deps.Authorization = s.authorizer
	x.attempt.Challenge.Binding.Session = "proof"
	x.attempt.Challenge.Credential = &store.AppAttestShadowKey{KeyID: s.evidence.Binding.Credential}
	x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = "assertion", "current-challenge"
	archive := &capturedRecoveryArchive{MemoryStore: h.mem}
	x.deps.Archive = archive
	reply := protocol.AppAttestShadowPayload{
		Session: x.attempt.Challenge.Binding.Session, Action: "assertion", Result: "ok", KeyID: x.attempt.Challenge.Credential.KeyID,
		Challenge: "unsigned-wrong-challenge", Proof: "AQID",
	}
	if next := x.accept(context.Background(), reply); next != "stop" || x.last.Outcome != "challenge_mismatch" {
		t.Fatalf("unexpected mismatch result: next=%s outcome=%s", next, x.last.Outcome)
	}
	s.authorizer.RejectProof(p, x.last.Outcome)
	if archive.evidence.ProofField != reply.Proof || archive.evidence.SessionID != p.ID {
		t.Fatal("unsigned failed proof was not archived")
	}
	if eligibility.ProofViolation("challenge_mismatch") || !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("unsigned reply fields hard-denied a valid MDM/APNs provider")
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.Current(p) != nil {
		t.Fatal("unsigned mismatch created an App Attest grant")
	}
	firstSession := x.attempt.Challenge.Binding.Session
	attempts, retries := 0, 0
	x.drive(context.Background(), func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
		attempts++
		if attempts == 1 {
			if next := x.accept(ctx, reply); next != "stop" {
				t.Fatalf("mismatch unexpectedly advanced exchange: %s", next)
			}
		} else {
			if binding.Session == firstSession || x.attempt.Challenge.Credential != nil {
				t.Fatal("retry reused the old challenge session or cached key")
			}
			return recovery.Outcome{Reason: "unsupported"}
		}
		return recovery.Outcome{Reason: x.last.Outcome}
	}, func(_ context.Context, delay time.Duration) bool {
		retries++
		if delay != time.Minute || !s.registry.ProviderLegacyServingAuthorized(p) {
			t.Fatal("mismatch did not schedule bounded recovery while preserving legacy")
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("mismatch retry granted App Attest without a fresh proof")
		}
		return true
	}, func(reason string) { s.authorizer.RejectProof(p, reason) })
	if attempts != 2 || retries != 1 {
		t.Fatalf("mismatch retry attempts=%d waits=%d", attempts, retries)
	}
}

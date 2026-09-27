package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestAppAttestRecoveryPreservesFailuresAndDoesNotAuthorizePostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	evidence := AppAttestEvidence{ID: "enrollment", SessionID: "session", KeyID: "key", ReceivedAt: now.Add(-10 * time.Minute), Action: "attestation", Proof: []byte{1}, Context: json.RawMessage(`{}`)}
	if err := s.BeginAppAttestEvidence(ctx, evidence); err != nil {
		t.Fatal(err)
	}
	key := AppAttestShadowKey{KeyID: "key", Owner: "owner", AccountID: "account", PublicKey: []byte{2}}
	receipt := AppAttestReceipt{ID: "old", KeyID: "key", EvidenceID: evidence.ID, ReceivedAt: now, Outcome: "receipt_creation_time", Body: []byte{3}, Context: json.RawMessage(`{}`), Details: json.RawMessage(`{}`), NextAt: now}
	if _, err := s.CompleteAppAttestEvidence(ctx, evidence.ID, AppAttestDecision{Outcome: "verified", Key: &key, Receipt: &receipt}); err != nil {
		t.Fatal(err)
	}
	if r, err := s.ClaimAppAttestReceipt(ctx, now); err != nil || r != nil {
		t.Fatal("invalid receipt automatically trusted", err)
	}
	if n, err := s.QueueAppAttestReceiptRecovery(ctx, 100); err != nil || n != 1 {
		t.Fatalf("recovery seed %d %v", n, err)
	}
	if n, err := s.QueueAppAttestReceiptRecovery(ctx, 100); err != nil || n != 0 {
		t.Fatal("duplicate recovery", err)
	}
	claimed, err := s.ClaimAppAttestReceipt(ctx, now.Add(time.Second))
	if err != nil || claimed == nil || claimed.Outcome != "receipt_creation_time" {
		t.Fatalf("%+v %v", claimed, err)
	}
	recovered := receipt
	recovered.ID = "historical-validation"
	recovered.ParentID = "old"
	recovered.Outcome = "renewal_required"
	recovered.ExpiresAt = now.Add(time.Hour)
	recovered.NextAt = now
	if err := s.SaveAppAttestReceiptRefresh(ctx, recovered); err != nil {
		t.Fatal(err)
	}
	state, err := s.GetAppAttestReadiness(ctx, "key")
	if err != nil || state.Receipt != nil {
		t.Fatal("historical receipt counted as freshly verified", err)
	}
	var outcome string
	if err := s.pool.QueryRow(ctx, `SELECT outcome FROM app_attest_receipts WHERE id='old'`).Scan(&outcome); err != nil || outcome != "receipt_creation_time" {
		t.Fatal("history rewritten", err)
	}
	pending := evidence
	pending.ID = "interrupted"
	pending.Action = "assertion"
	if err := s.BeginAppAttestEvidence(ctx, pending); err != nil {
		t.Fatal(err)
	}
	if n, err := s.ReconcileAppAttestEvidence(ctx, now.Add(-5*time.Minute), 100); err != nil || n != 1 {
		t.Fatalf("reconcile %d %v", n, err)
	}
	counter := uint32(99)
	if outcome, err := s.CompleteAppAttestEvidence(ctx, pending.ID, AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: "key", Owner: "owner"}); err != nil || outcome != "interrupted" {
		t.Fatalf("stale completion won %s %v", outcome, err)
	}
	k, _ := s.GetAppAttestShadowKey(ctx, "key")
	if k.Counter != 0 {
		t.Fatal("reconciler advanced counter")
	}
}

func TestAppAttestRevocationIsAccountScopedAndDurable(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			keys, ok := As[AppAttestShadowStore](backend)
			if !ok {
				t.Fatal("key store hidden")
			}
			readiness, ok := As[AppAttestReadinessStore](backend)
			if !ok {
				t.Fatal("revocation store hidden")
			}
			ctx := context.Background()
			_, err := keys.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: "revoked", Owner: "owner", AccountID: "account"})
			if err != nil {
				t.Fatal(err)
			}
			if changed, err := readiness.RevokeAppAttestKey(ctx, "revoked", "other", "test"); err != nil || changed {
				t.Fatal("cross-account revocation", err)
			}
			if changed, err := readiness.RevokeAppAttestKey(ctx, "revoked", "account", "test"); err != nil || !changed {
				t.Fatal("revoke", err)
			}
			if changed, err := readiness.RevokeAppAttestKey(ctx, "revoked", "account", "test"); err != nil || changed {
				t.Fatal("duplicate changed history", err)
			}
			state, err := readiness.GetAppAttestReadiness(ctx, "revoked")
			if err != nil || !state.Revoked {
				t.Fatal("revocation missing", err)
			}
		})
	}
}

func TestAppAttestMachineIdentitySurvivesWithoutLegacyProof(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			s, ok := As[MachineInventoryStore](backend)
			if !ok {
				t.Fatal("inventory missing")
			}
			ctx := context.Background()
			now := time.Now()
			initial := MachineObservation{SessionID: "first", AccountID: "account", At: now, SEKey: "legacy", VerifiedSerial: "hardware", VerifiedAppAttestKey: "verified-app-key"}
			first, err := s.ObserveMachine(ctx, initial)
			if err != nil {
				t.Fatal(err)
			}
			next := MachineObservation{SessionID: "next", AccountID: "account", At: now.Add(time.Second)}
			provisional, err := s.ObserveMachine(ctx, next)
			if err != nil {
				t.Fatal(err)
			}
			if provisional.ID == first.ID {
				t.Fatal("unverified registration inherited identity")
			}
			next.At = now.Add(2 * time.Second)
			next.VerifiedAppAttestKey = "verified-app-key"
			rebound, err := s.ObserveMachine(ctx, next)
			if err != nil || rebound.ID != first.ID {
				t.Fatalf("identity lost without MDM: %+v %v", rebound, err)
			}
			next.SessionID = "other-account"
			next.AccountID = "other"
			other, err := s.ObserveMachine(ctx, next)
			if err != nil || other.ID == first.ID {
				t.Fatal("credential alias crossed accounts", err)
			}
		})
	}
}

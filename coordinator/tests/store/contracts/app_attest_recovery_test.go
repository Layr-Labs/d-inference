package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestRevocationIsAccountScopedAndDurable(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			keys, ok := store.As[store.AppAttestShadowStore](backend)
			if !ok {
				t.Fatal("key store hidden")
			}
			readiness, ok := store.As[store.AppAttestReadinessStore](backend)
			if !ok {
				t.Fatal("revocation store hidden")
			}
			ctx := context.Background()
			_, err := keys.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: "revoked", Owner: "owner", AccountID: "account"})
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
			s, ok := store.As[store.MachineInventoryStore](backend)
			if !ok {
				t.Fatal("inventory missing")
			}
			ctx := context.Background()
			now := time.Now()
			initial := store.MachineObservation{SessionID: "first", AccountID: "account", At: now, SEKey: "legacy", VerifiedSerial: "hardware", VerifiedAppAttestKey: "verified-app-key"}
			first, err := s.ObserveMachine(ctx, initial)
			if err != nil {
				t.Fatal(err)
			}
			next := store.MachineObservation{SessionID: "next", AccountID: "account", At: now.Add(time.Second)}
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

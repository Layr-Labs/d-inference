package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFreshProofCanRepairOnlyLiveHistoricalInventoryTombstone(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := store.As[store.MachineInventoryStore](backend)
			continuity, _ := store.As[store.MachineOperationalStore](backend)
			recovery, ok := store.As[store.MachineContinuityRecoveryStore](store.NewCached(backend, store.DefaultCacheConfig()))
			if !ok {
				t.Fatal("cache hid recovery capability")
			}
			keys, _ := store.As[store.AppAttestShadowStore](backend)
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-10 * time.Minute)
			if _, err := keys.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: "new-apple-key", AccountID: "owner", Owner: "owner"}); err != nil {
				t.Fatal(err)
			}
			// Backfill won before the first live capture. No App Attest alias
			// exists yet; only a fresh verified assertion can supply it.
			historical := store.MachineObservation{SessionID: "live", AccountID: "owner", At: old,
				Source: "historical_registration", Disconnected: true}
			if _, err := inventory.ObserveMachine(ctx, historical); err != nil {
				t.Fatal(err)
			}
			if err := backend.OpenProviderSession(ctx, "live", "", "owner"); err != nil {
				t.Fatal(err)
			}
			if err := backend.TouchProviderSession(ctx, "live", "", "owner", "endpoint", now); err != nil {
				t.Fatal(err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
				t.Fatalf("historical tombstone granted without repair: %v", err)
			}
			if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, "live", "other", "new-apple-key", now); err != nil || repaired {
				t.Fatalf("cross-account repair: %v %v", repaired, err)
			}
			if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, "live", "owner", "unknown-key", now); err != nil || repaired {
				t.Fatalf("unknown-key repair: %v %v", repaired, err)
			}
			if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, "live", "owner", "new-apple-key", now); err != nil || !repaired {
				t.Fatalf("live historical repair: %v %v", repaired, err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
				t.Fatalf("reopening alone granted without verified alias: %v", err)
			}
			live := store.MachineObservation{SessionID: "live", AccountID: "owner", At: now.Add(time.Second),
				Source: "live_registration", VerifiedAppAttestKey: "new-apple-key"}
			id, err := inventory.ObserveMachine(ctx, live)
			if err != nil {
				t.Fatal(err)
			}
			got, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil)
			if err != nil || got.Machine.ID != id.ID || got.Machine.Assurance != "key_bound" {
				t.Fatalf("fresh alias did not restore strict continuity: %+v %v", got, err)
			}
			if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, "live", "owner", "new-apple-key", now.Add(time.Second)); err != nil || repaired {
				t.Fatalf("open session repaired twice: %v %v", repaired, err)
			}
			live.Disconnected, live.At = true, now.Add(2*time.Second)
			if _, err := inventory.ObserveMachine(ctx, live); err != nil {
				t.Fatal(err)
			}
			if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, "live", "owner", "new-apple-key", now.Add(3*time.Second)); err != nil || repaired {
				t.Fatalf("real live-session close reopened: %v %v", repaired, err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, store.ErrMachineContinuityUnverified) {
				t.Fatalf("terminated session retained continuity: %v", err)
			}
		})
	}
}

func TestHistoricalRepairRejectsClosedStaleRevokedAndRealDisconnect(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := store.As[store.MachineInventoryStore](backend)
			recovery, _ := store.As[store.MachineContinuityRecoveryStore](backend)
			keys, _ := store.As[store.AppAttestShadowStore](backend)
			readiness, _ := store.As[store.AppAttestReadinessStore](backend)
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-10 * time.Minute)
			for _, id := range []string{"closed", "stale", "revoked", "real-disconnect", "alias-mismatch"} {
				if _, err := keys.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: id, AccountID: "owner", Owner: "owner"}); err != nil {
					t.Fatal(err)
				}
				o := store.MachineObservation{SessionID: id, AccountID: "owner", At: old, Source: "historical_registration", Disconnected: true}
				if id == "real-disconnect" {
					o.Source = "live_registration"
				}
				if id == "alias-mismatch" {
					// The existing credential alias belongs to a different
					// canonical machine; recovery cannot rewrite this tombstone.
					if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "prior-alias", AccountID: "owner", At: old, VerifiedAppAttestKey: id}); err != nil {
						t.Fatal(err)
					}
				}
				if _, err := inventory.ObserveMachine(ctx, o); err != nil {
					t.Fatal(err)
				}
				if err := backend.OpenProviderSession(ctx, id, "", "owner"); err != nil {
					t.Fatal(err)
				}
				heartbeat := now
				if id == "stale" {
					heartbeat = old.Add(time.Minute)
				}
				if err := backend.TouchProviderSession(ctx, id, "", "owner", "endpoint", heartbeat); err != nil {
					t.Fatal(err)
				}
			}
			if err := backend.CloseProviderSession(ctx, "closed", "disconnect", now); err != nil {
				t.Fatal(err)
			}
			if changed, err := readiness.RevokeAppAttestKey(ctx, "revoked", "owner", "test"); err != nil || !changed {
				t.Fatalf("revoke fixture: %v %v", changed, err)
			}
			for _, id := range []string{"closed", "stale", "revoked", "real-disconnect", "alias-mismatch"} {
				if repaired, err := recovery.RecoverLiveAppAttestMachineSession(ctx, id, "owner", id, now); err != nil || repaired {
					t.Fatalf("%s bypassed terminal guard: %v %v", id, repaired, err)
				}
			}
		})
	}
}

package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestFreshProofCanRepairOnlyLiveHistoricalInventoryTombstone(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := As[MachineInventoryStore](backend)
			continuity, _ := As[MachineOperationalStore](backend)
			recovery, ok := As[MachineContinuityRecoveryStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("cache hid recovery capability")
			}
			keys, _ := As[AppAttestShadowStore](backend)
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-10 * time.Minute)
			if _, err := keys.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: "new-apple-key", AccountID: "owner", Owner: "owner"}); err != nil {
				t.Fatal(err)
			}
			// Backfill won before the first live capture. No App Attest alias
			// exists yet; only a fresh verified assertion can supply it.
			historical := MachineObservation{SessionID: "live", AccountID: "owner", At: old,
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
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
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
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("reopening alone granted without verified alias: %v", err)
			}
			live := MachineObservation{SessionID: "live", AccountID: "owner", At: now.Add(time.Second),
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
			if _, err := continuity.ResolveMachineContinuity(ctx, "live", "owner", "new-apple-key", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("terminated session retained continuity: %v", err)
			}
		})
	}
}

func TestHistoricalRepairRejectsClosedStaleRevokedAndRealDisconnect(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := As[MachineInventoryStore](backend)
			recovery, _ := As[MachineContinuityRecoveryStore](backend)
			keys, _ := As[AppAttestShadowStore](backend)
			readiness, _ := As[AppAttestReadinessStore](backend)
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-10 * time.Minute)
			for _, id := range []string{"closed", "stale", "revoked", "real-disconnect", "alias-mismatch"} {
				if _, err := keys.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: id, AccountID: "owner", Owner: "owner"}); err != nil {
					t.Fatal(err)
				}
				o := MachineObservation{SessionID: id, AccountID: "owner", At: old, Source: "historical_registration", Disconnected: true}
				if id == "real-disconnect" {
					o.Source = "live_registration"
				}
				if id == "alias-mismatch" {
					// The existing credential alias belongs to a different
					// canonical machine; recovery cannot rewrite this tombstone.
					if _, err := inventory.ObserveMachine(ctx, MachineObservation{SessionID: "prior-alias", AccountID: "owner", At: old, VerifiedAppAttestKey: id}); err != nil {
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

func TestInventoryBackfillExcludesRecentAndOpenProviderSessions(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	for _, entry := range []struct {
		id   string
		seen time.Time
		open bool
	}{
		{"recent", now, false}, {"open", now.Add(-10 * time.Minute), true},
		{"historical", now.Add(-10 * time.Minute), false},
	} {
		if err := s.UpsertProvider(ctx, ProviderRecord{ID: entry.id, AccountID: "owner", LastSeen: entry.seen, Hardware: []byte(`{}`), Models: []byte(`[]`)}); err != nil {
			t.Fatal(err)
		}
		if entry.open {
			if err := s.OpenProviderSession(ctx, entry.id, "", "owner"); err != nil {
				t.Fatal(err)
			}
		}
	}
	n, err := s.BackfillMachineInventory(ctx, 100)
	if err != nil || n != 1 {
		t.Fatalf("backfill selected live/recent provider: %d %v", n, err)
	}
	if r := readInventorySession(t, s, "historical"); !r.closed || r.observation.Source != "historical_registration" {
		t.Fatalf("historical provider not backfilled: %+v", r)
	}
	for _, id := range []string{"recent", "open"} {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM darkbloom_machine_sessions WHERE session_id=$1)`, id).Scan(&exists); err != nil || exists {
			t.Fatalf("%s received a false tombstone: %v %v", id, exists, err)
		}
	}
}

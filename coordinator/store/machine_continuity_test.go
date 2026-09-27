package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

func TestMachineContinuityPreservesAccountHistoryAcrossKeyRotation(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			inventory, _ := As[MachineInventoryStore](backend)
			keys, _ := As[AppAttestShadowStore](backend)
			continuity, ok := As[MachineOperationalStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("decorator hides machine continuity")
			}
			observe := func(session, account, se, serial, key string) MachineIdentity {
				t.Helper()
				id, err := inventory.ObserveMachine(ctx, MachineObservation{SessionID: session, AccountID: account, At: now, SEKey: se, VerifiedSerial: serial, VerifiedAppAttestKey: key})
				if err != nil {
					t.Fatal(err)
				}
				return id
			}
			for _, key := range []AppAttestShadowKey{{KeyID: "apple", AccountID: "owner"}, {KeyID: "rotated", AccountID: "owner"}, {KeyID: "other-apple", AccountID: "other"}} {
				if _, err := keys.InsertAppAttestShadowKey(ctx, key); err != nil {
					t.Fatal(err)
				}
			}
			original := observe("original", "owner", "legacy-se", "apple-serial", "apple")
			prior := ProviderRecord{ID: "original", AccountID: "owner", Hardware: []byte(`{}`), Models: []byte(`[]`), SEPublicKey: "legacy-se", SerialNumber: "apple-serial", PublicKey: "old-encryption-key", LifetimeTokensGenerated: 700, LastSeen: now.Add(-time.Minute)}
			if err := backend.UpsertProvider(ctx, prior); err != nil {
				t.Fatal(err)
			}
			if err := backend.RecordProviderEarning(&ProviderEarning{AccountID: "owner", ProviderID: prior.ID, ProviderKey: prior.PublicKey, JobID: "original-job", Model: "model", AmountMicroUSD: 123, CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
			before, err := backend.GetAccountEarnings("owner", 20)
			if err != nil {
				t.Fatal(err)
			}

			// A new SE key and no MDM proof do not inherit history until a fresh
			// App Attest assertion has associated the account-scoped alias.
			observe("reconnect", "owner", "new-se", "", "")
			if _, err := continuity.ResolveMachineContinuity(ctx, "reconnect", "owner", "apple", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("unproved reconnect inherited history: %v", err)
			}
			observe("reconnect", "owner", "new-se", "", "apple")
			got, err := continuity.ResolveMachineContinuity(ctx, "reconnect", "owner", "apple", nil)
			if err != nil || got.Machine.ID != original.ID || got.Previous == nil || got.Previous.ID != prior.ID || got.Previous.LifetimeTokensGenerated != 700 || got.Previous.PublicKey != prior.PublicKey {
				t.Fatalf("lost canonical history: %+v %v", got, err)
			}
			if excluded, err := continuity.ResolveMachineContinuity(ctx, "reconnect", "owner", "apple", []string{prior.ID}); err != nil || excluded.Previous != nil {
				t.Fatalf("restored live provider history: %+v %v", excluded, err)
			}

			// A newer row claiming the serial is unrelated to the verified machine.
			observe("serial-imposter", "owner", "unrelated-se", "", "")
			if err := backend.UpsertProvider(ctx, ProviderRecord{ID: "serial-imposter", AccountID: "owner", Hardware: []byte(`{}`), Models: []byte(`[]`), SerialNumber: prior.SerialNumber, LifetimeTokensGenerated: 9999, LastSeen: now.Add(time.Minute)}); err != nil {
				t.Fatal(err)
			}
			// A genuinely shared verified hardware identity also cannot transfer
			// another account's reputation, counters or payout keys.
			observe("other-account", "other", "other-se", "apple-serial", "other-apple")
			if err := backend.UpsertProvider(ctx, ProviderRecord{ID: "other-account", AccountID: "other", Hardware: []byte(`{}`), Models: []byte(`[]`), LifetimeTokensGenerated: 8888, LastSeen: now.Add(2 * time.Minute)}); err != nil {
				t.Fatal(err)
			}
			got, err = continuity.ResolveMachineContinuity(ctx, "reconnect", "owner", "apple", nil)
			if err != nil || got.Previous == nil || got.Previous.ID != prior.ID {
				t.Fatalf("serial/account identity contamination: %+v %v", got, err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "reconnect", "other", "other-apple", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("cross-account session accepted: %v", err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "reconnect", "owner", "other-apple", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("cross-account credential accepted: %v", err)
			}

			// A fresh assertion with a rotated Apple key associates through the
			// already authenticated SE alias; no serial or ledger key is rewritten.
			observe("rotation", "owner", "new-se", "", "rotated")
			got, err = continuity.ResolveMachineContinuity(ctx, "rotation", "owner", "rotated", nil)
			if err != nil || got.Machine.ID != original.ID || got.Previous == nil || got.Previous.ID != prior.ID {
				t.Fatalf("credential rotation lost history: %+v %v", got, err)
			}
			after, err := backend.GetAccountEarnings("owner", 20)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatalf("identity lookup rewrote ledger rows: %v", err)
			}
			readiness, _ := As[AppAttestReadinessStore](backend)
			if changed, err := readiness.RevokeAppAttestKey(ctx, "rotated", "owner", "test"); err != nil || !changed {
				t.Fatalf("revoke: %v", err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "rotation", "owner", "rotated", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("revoked key restored history: %v", err)
			}
		})
	}
}

func TestMachineContinuityNewProviderRequiresLiveVerifiedAssociation(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := As[MachineInventoryStore](backend)
			keys, _ := As[AppAttestShadowStore](backend)
			continuity, _ := As[MachineOperationalStore](backend)
			if _, err := keys.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: "fresh", AccountID: "owner"}); err != nil {
				t.Fatal(err)
			}
			now := time.Now().UTC()
			o := MachineObservation{SessionID: "new", AccountID: "owner", At: now, VerifiedAppAttestKey: "fresh"}
			id, err := inventory.ObserveMachine(ctx, o)
			if err != nil {
				t.Fatal(err)
			}
			got, err := continuity.ResolveMachineContinuity(ctx, "new", "owner", "fresh", nil)
			if err != nil || got.Machine.ID != id.ID || got.Machine.Assurance != "key_bound" || got.Previous != nil {
				t.Fatalf("new App Attest-only machine: %+v %v", got, err)
			}
			for _, input := range [][3]string{{"", "owner", "fresh"}, {"new", "", "fresh"}, {"new", "owner", ""}, {"new", "owner", "unknown"}} {
				if _, err := continuity.ResolveMachineContinuity(ctx, input[0], input[1], input[2], nil); !errors.Is(err, ErrMachineContinuityUnverified) {
					t.Fatalf("incomplete identity accepted: %v", err)
				}
			}
			o.At, o.Disconnected = now.Add(time.Second), true
			if _, err := inventory.ObserveMachine(ctx, o); err != nil {
				t.Fatal(err)
			}
			if _, err := continuity.ResolveMachineContinuity(ctx, "new", "owner", "fresh", nil); !errors.Is(err, ErrMachineContinuityUnverified) {
				t.Fatalf("disconnected session accepted: %v", err)
			}
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			if _, err := continuity.ResolveMachineContinuity(cancelled, "new", "owner", "fresh", nil); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancellation ignored: %v", err)
			}
		})
	}
}

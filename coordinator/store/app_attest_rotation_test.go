package store

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func archiveAppAttestOutcome(t *testing.T, archive AppAttestArchiveStore, id, session, key, action, outcome string, at time.Time, context map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(context)
	ctx := t.Context()
	if err := archive.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: id, SessionID: session, KeyID: key, ReceivedAt: at, Action: action, SHA256: "sum", Context: raw}); err != nil {
		t.Fatal(err)
	}
	if _, err := archive.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: outcome}); err != nil {
		t.Fatal(err)
	}
}

func TestAppAttestKeyRotationRecordIsInsertOnceAndRateScoped(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			rotations, ok := As[AppAttestKeyRotationStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("rotation storage hidden by decorator")
			}
			now := time.Now().UTC().Truncate(time.Microsecond)
			first := AppAttestKeyRotation{KeyID: "dead", MachineID: "machine", AccountID: "account", RequestedAt: now, Failures: 2, Reason: "assertion_apple_error"}
			if inserted, err := rotations.RecordAppAttestKeyRotation(ctx, first); err != nil || !inserted {
				t.Fatalf("first record: %v %v", inserted, err)
			}
			again := first
			again.RequestedAt, again.Failures = now.Add(time.Minute), 9
			if inserted, err := rotations.RecordAppAttestKeyRotation(ctx, again); err != nil || inserted {
				t.Fatalf("second record for one key inserted: %v %v", inserted, err)
			}
			got, err := rotations.GetAppAttestKeyRotation(ctx, "dead")
			if err != nil || got == nil || !got.RequestedAt.Equal(now) || got.Failures != 2 || got.MachineID != "machine" {
				t.Fatalf("original rotation not retained: %+v %v", got, err)
			}
			if missing, err := rotations.GetAppAttestKeyRotation(ctx, "absent"); err != nil || missing != nil {
				t.Fatalf("absent rotation: %+v %v", missing, err)
			}
			for i, at := range []time.Time{now.Add(-2 * time.Hour), now.Add(-25 * time.Hour)} {
				r := first
				r.KeyID, r.RequestedAt = fmt.Sprintf("older-%d", i), at
				if _, err := rotations.RecordAppAttestKeyRotation(ctx, r); err != nil {
					t.Fatal(err)
				}
			}
			other := first
			other.KeyID, other.MachineID = "other-machine-key", "other"
			if _, err := rotations.RecordAppAttestKeyRotation(ctx, other); err != nil {
				t.Fatal(err)
			}
			for since, want := range map[time.Time]int{now.Add(-time.Hour): 1, now.Add(-24 * time.Hour): 2, now.Add(-48 * time.Hour): 3} {
				if n, err := rotations.CountAppAttestKeyRotations(ctx, "machine", since); err != nil || n != want {
					t.Fatalf("rotations since %s = %d, want %d (%v)", now.Sub(since), n, want, err)
				}
			}
		})
	}
}

func TestAppAttestRotationFailuresCountOnlyDeadKeySignals(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			archive, _ := As[AppAttestArchiveStore](backend)
			rotations, _ := As[AppAttestKeyRotationStore](backend)
			now := time.Now().UTC().Truncate(time.Microsecond)
			devicecheck := func(code int) map[string]any {
				return map[string]any{"key_id": "dead", "apple_error": map[string]any{"domain": "devicecheck", "code": code}}
			}
			for i, tc := range []struct {
				action, outcome string
				at              time.Time
				context         map[string]any
			}{
				{"assertion", "apple_error", now, map[string]any{"key_id": "dead"}}, // 0.9.8: bare apple_error
				{"assertion", "apple_error", now, devicecheck(0)},
				{"assertion", "apple_error", now, devicecheck(2)},
				// Never rotation evidence:
				{"assertion", "apple_error", now, devicecheck(3)},
				{"assertion", "apple_error", now, map[string]any{"key_id": "dead", "apple_error": map[string]any{"domain": "osstatus", "code": 0}}},
				{"assertion", "apple_error", now, map[string]any{"key_id": "dead", "apple_error_source": "proof_oversize"}},
				{"assertion", "apple_unavailable", now, map[string]any{"key_id": "dead"}},
				{"assertion", "busy", now, map[string]any{"key_id": "dead"}},
				{"assertion", "operation_timeout", now, map[string]any{"key_id": "dead"}},
				{"assertion", "unsupported", now, map[string]any{"key_id": "dead"}},
				{"attestation", "apple_error", now, map[string]any{"key_id": "dead"}},
				{"assertion", "apple_error", now.Add(-2 * time.Hour), map[string]any{"key_id": "dead"}},
				// A client-chosen key ID cannot charge another credential.
				{"assertion", "apple_error", now, map[string]any{"key_id": "someone-else"}},
			} {
				archiveAppAttestOutcome(t, archive, fmt.Sprintf("e-%d", i), "session", "dead", tc.action, tc.outcome, tc.at, tc.context)
			}
			if n, err := rotations.CountAppAttestRotationFailures(ctx, "dead", now.Add(-time.Hour)); err != nil || n != 3 {
				t.Fatalf("eligible failures = %d, want 3 (%v)", n, err)
			}
			if n, err := rotations.CountAppAttestRotationFailures(ctx, "dead", now.Add(-3*time.Hour)); err != nil || n != 4 {
				t.Fatalf("eligible failures with older window = %d, want 4 (%v)", n, err)
			}
			if n, err := rotations.CountAppAttestRotationFailures(ctx, "dead", now.Add(time.Second)); err != nil || n != 0 {
				t.Fatalf("failures before the last verified assertion counted: %d (%v)", n, err)
			}
		})
	}
}

func TestAppAttestEnrollmentInvalidKeyFailuresFollowCanonicalMachine(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			archive, _ := As[AppAttestArchiveStore](backend)
			inventory, _ := As[MachineInventoryStore](backend)
			rotations, _ := As[AppAttestKeyRotationStore](backend)
			now := time.Now().UTC().Truncate(time.Microsecond)
			observe := func(session, account, se string) string {
				id, err := inventory.ObserveMachine(ctx, MachineObservation{SessionID: session, AccountID: account, SEKey: se, At: now})
				if err != nil {
					t.Fatal(err)
				}
				return id.ID
			}
			machine := observe("first", "account", "se")
			if observe("second", "account", "se") != machine {
				t.Fatal("fixture sessions not on one machine")
			}
			other := observe("other", "account", "other-se")
			for i, tc := range []struct {
				session, action, outcome string
				at                       time.Time
			}{
				{"first", "attestation", "apple_invalid_key", now},
				{"second", "attestation", "apple_invalid_key", now.Add(-time.Hour)},
				{"first", "attestation", "apple_invalid_key", now.Add(-25 * time.Hour)},
				{"first", "attestation", "apple_error", now},
				{"first", "assertion", "apple_invalid_key", now},
				{"other", "attestation", "apple_invalid_key", now},
				{"unknown-session", "attestation", "apple_invalid_key", now},
			} {
				archiveAppAttestOutcome(t, archive, fmt.Sprintf("k-%d", i), tc.session, fmt.Sprintf("fresh-%d", i), tc.action, tc.outcome, tc.at, map[string]any{})
			}
			since := now.Add(-24 * time.Hour)
			if n, err := rotations.CountAppAttestEnrollmentInvalidKeyFailures(ctx, machine, "account", since); err != nil || n != 2 {
				t.Fatalf("machine failures = %d, want 2 (%v)", n, err)
			}
			if n, err := rotations.CountAppAttestEnrollmentInvalidKeyFailures(ctx, other, "account", since); err != nil || n != 1 {
				t.Fatalf("other machine failures = %d, want 1 (%v)", n, err)
			}
			if n, err := rotations.CountAppAttestEnrollmentInvalidKeyFailures(ctx, "", "account", since); err != nil || n != 3 {
				t.Fatalf("account fallback failures = %d, want 3 (%v)", n, err)
			}
			if n, err := rotations.CountAppAttestEnrollmentInvalidKeyFailures(ctx, "", "", since); err != nil || n != 0 {
				t.Fatalf("unscoped count = %d (%v)", n, err)
			}
		})
	}
}

func TestAppAttestShadowKeyUpdatedAtTracksLastAcceptedAssertion(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			keys, _ := As[AppAttestShadowStore](backend)
			before := time.Now().Add(-time.Second)
			key := AppAttestShadowKey{KeyID: "key", Owner: "owner", PublicKey: []byte{1}}
			if _, err := keys.InsertAppAttestShadowKey(ctx, key); err != nil {
				t.Fatal(err)
			}
			enrolled, _ := keys.GetAppAttestShadowKey(ctx, "key")
			if enrolled == nil || enrolled.UpdatedAt.Before(before) {
				t.Fatalf("new key has no enrollment time: %+v", enrolled)
			}
			if _, err := keys.AdvanceAppAttestShadowCounter(ctx, "key", "owner", 1); err != nil {
				t.Fatal(err)
			}
			advanced, _ := keys.GetAppAttestShadowKey(ctx, "key")
			if advanced.UpdatedAt.Before(enrolled.UpdatedAt) {
				t.Fatal("verified assertion did not move the rotation window forward")
			}
			if ok, _ := keys.AdvanceAppAttestShadowCounter(ctx, "key", "owner", 1); ok {
				t.Fatal("replayed counter accepted")
			}
			replayed, _ := keys.GetAppAttestShadowKey(ctx, "key")
			if !replayed.UpdatedAt.Equal(advanced.UpdatedAt) {
				t.Fatal("rejected counter moved the rotation window")
			}
		})
	}
}

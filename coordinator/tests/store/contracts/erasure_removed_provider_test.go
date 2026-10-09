package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestRemovedProviderIdentityRemainsErasable(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			rec := store.ProviderTrustReuse{SEPubKey: a.SEKey, Serial: "private-removed-serial", MDAUDID: "private-removed-udid", TrustLevel: "hardware", HardwareProofVerifiedAt: now}
			if _, err := s.UpsertProviderTrustReuse(ctx, rec, 0); err != nil {
				t.Fatal(err)
			}
			proof := store.CodeAttestation{SEPubKey: a.SEKey, APNsToken: "private-removed-token", AttestedAt: now}
			if err := s.UpsertCodeAttestation(ctx, proof); err != nil {
				t.Fatal(err)
			}
			if _, err := s.UpsertVerificationJob(ctx, store.VerificationJob{SEPubKey: a.SEKey, Serial: rec.Serial, UDID: rec.MDAUDID, Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending, UpdatedAt: now}); err != nil {
				t.Fatal(err)
			}
			if err := s.UpsertReputation(ctx, a.ProviderID, store.ReputationRecord{TotalJobs: 1}); err != nil {
				t.Fatal(err)
			}
			for _, want := range []int{1, 0} {
				if n, err := s.DeleteProvidersBySerial(ctx, a.AccountID, a.ProviderID); err != nil || n != want {
					t.Fatalf("remove=%d %v, want %d", n, err, want)
				}
			}
			if p, err := s.GetProviderRecord(ctx, a.ProviderID); err == nil || p != nil {
				t.Fatalf("removed provider visible: %+v %v", p, err)
			}
			if r, err := s.GetReputation(ctx, a.ProviderID); r != nil || err == nil {
				t.Fatalf("removed reputation: %+v %v", r, err)
			}
			// Cancellation must restore only providers removed by this request.
			now = time.Now().UTC()
			req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now); err != nil {
				t.Fatal(err)
			}
			if p, err := s.GetProviderRecord(ctx, a.ProviderID); err == nil || p != nil {
				t.Fatalf("cancel revived removed provider: %+v %v", p, err)
			}
			req = erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			result, err := s.ScrubAccount(ctx, req.ID, now)
			if err != nil {
				t.Fatal(err)
			}
			if len(result.SEKeys) != 1 || result.SEKeys[0] != a.SEKey {
				t.Fatalf("removed SE not collected: %+v", result.SEKeys)
			}
			rows, err := s.ListProviderTrustReuse(ctx)
			if err != nil {
				t.Fatal(err)
			}
			for _, row := range rows {
				if row.SEPubKey == a.SEKey && (row.Serial != "" || row.MDAUDID != "") {
					t.Fatalf("removed trust escaped scrub: %+v", row)
				}
			}
			proofs, err := s.ListCodeAttestations(ctx)
			if err != nil {
				t.Fatal(err)
			}
			for _, row := range proofs {
				if row.SEPubKey == a.SEKey && row.APNsToken != "" {
					t.Fatalf("removed proof escaped scrub: %+v", row)
				}
			}
			if _, err := s.UpsertProviderTrustReuse(ctx, rec, 0); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("removed identity callback restored: %v", err)
			}
			if err := s.UpsertCodeAttestation(ctx, proof); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("removed identity proof restored: %v", err)
			}
		})
	}
}

// Older removals may have no provider row but still have the authenticated,
// account-scoped legacy SE alias captured by inventory. It is an ownership link;
// serial claims and the session's X25519 provider key are not.
func TestErasureHistoricalSEOwnership(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a, b := erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s)
			inv, ok := store.As[store.MachineInventoryStore](s)
			if !ok {
				t.Fatal("inventory unavailable")
			}
			now := time.Now().UTC()
			key := erasurefixture.UniqueID("historical-se")
			for _, owner := range []erasurefixture.Account{a, b} {
				if _, err := inv.ObserveMachine(ctx, store.MachineObservation{SessionID: erasurefixture.UniqueID("historical-session"), AccountID: owner.AccountID, SEKey: key, VerifiedSerial: "historical-private-serial", At: now, Disconnected: true, Source: "live_registration"}); err != nil {
					t.Fatal(err)
				}
			}
			rec := store.ProviderTrustReuse{SEPubKey: key, Serial: "historical-private-serial", MDAUDID: "historical-private-udid", TrustLevel: "hardware", HardwareProofVerifiedAt: now}
			write := func() error { _, err := s.UpsertProviderTrustReuse(ctx, rec, 0); return err }
			if err := write(); err != nil {
				t.Fatal(err)
			}
			proof := store.CodeAttestation{SEPubKey: key, APNsToken: "historical-private-token", AttestedAt: now}
			if err := s.UpsertCodeAttestation(ctx, proof); err != nil {
				t.Fatal(err)
			}
			for index, owner := range []erasurefixture.Account{a, b} {
				req := erasurefixture.PlanAndConfirm(t, s, owner, now, 0)
				result, err := s.ScrubAccount(ctx, req.ID, now)
				if err != nil {
					t.Fatal(err)
				}
				found := false
				for _, se := range result.SEKeys {
					found = found || se == key
				}
				if found != (index == 1) {
					t.Fatalf("historical shared key collection after erase %d: %+v", index, result.SEKeys)
				}
				if index == 1 && erasurefixture.RowsFor(result.Request.Summary.Applied.Rows, "machine_aliases_mda_serial") != 1 {
					t.Fatal("historical machine alias survived its last owner")
				}
				err = write()
				if index == 0 {
					if err != nil {
						t.Fatalf("live historical co-owner rejected: %v", err)
					}
				} else {
					if !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("alias removal lost owner fence: %v", err)
					}
					if err := s.UpsertCodeAttestation(ctx, proof); !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("alias removal lost proof fence: %v", err)
					}
				}
			}
			// A subsequently authenticated live account may own the same machine.
			c := erasurefixture.SeedAccount(t, s)
			p, err := s.GetProviderRecord(ctx, c.ProviderID)
			if err != nil {
				t.Fatal(err)
			}
			p.SEPublicKey = key
			if err := s.UpsertProvider(ctx, *p); err != nil {
				t.Fatal(err)
			}
			if err := write(); err != nil {
				t.Fatalf("new live owner denied: %v", err)
			}
		})
	}
}

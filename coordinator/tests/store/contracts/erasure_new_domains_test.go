package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureRemovesFrozenMDMCohortAndHardwareInterest(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			a := erasurefixture.SeedAccount(t, s)
			b := erasurefixture.SeedAccount(t, s)
			inventory, ok := store.As[store.MachineInventoryStore](s)
			if !ok {
				t.Fatal("missing machine inventory")
			}
			cohort, ok := store.As[store.LegacyMDMCohortStore](s)
			if !ok {
				t.Fatal("missing legacy cohort")
			}
			interest, ok := store.As[store.SmallModelsInterestStore](s)
			if !ok {
				t.Fatal("missing hardware interest")
			}
			for _, acct := range []erasurefixture.Account{a, b} {
				provider, err := s.GetProviderRecord(ctx, acct.ProviderID)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: acct.ProviderID, AccountID: acct.AccountID, SEKey: acct.SEKey, At: now.Add(-time.Minute)}); err != nil {
					t.Fatal(err)
				}
				legacyMDMProof(t, s, *provider)
				if err := interest.UpsertSmallModelsInterest(ctx, store.SmallModelsInterest{AccountID: acct.AccountID, MacType: "laptop", Chip: "Apple M4", RAMGB: 16}); err != nil {
					t.Fatal(err)
				}
			}
			before, err := cohort.FreezeLegacyMDMCohort(ctx)
			if err != nil || len(before) != 2 {
				t.Fatalf("initial cohort=%+v %v", before, err)
			}
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			result, err := s.ScrubAccount(ctx, req.ID, now)
			if err != nil {
				t.Fatal(err)
			}
			for _, rule := range []string{"legacy_mdm_cohort", "small_models_interest"} {
				if n := erasurefixture.RowsFor(result.Request.Summary.Applied.Rows, rule); n != 1 {
					t.Errorf("%s erased %d rows, want1", rule, n)
				}
			}
			after, err := cohort.FreezeLegacyMDMCohort(ctx)
			if err != nil || len(after) != 1 || after[0].AccountID != b.AccountID {
				t.Fatalf("remaining cohort=%+v %v", after, err)
			}
			if _, err := interest.GetSmallModelsInterest(ctx, a.AccountID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("erased hardware interest=%v", err)
			}
			if _, err := interest.GetSmallModelsInterest(ctx, b.AccountID); err != nil {
				t.Fatal(err)
			}
			if err := interest.UpsertSmallModelsInterest(ctx, store.SmallModelsInterest{AccountID: a.AccountID, MacType: "late", Chip: "private", RAMGB: 16}); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("late hardware write=%v", err)
			}
		})
	}
}

func TestErasureCanceledStagedObjectsReachLaterCleanup(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			a := erasurefixture.SeedAccount(t, s)
			req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			late := erasurefixture.UniqueID("acct_late")
			if err := s.SetUserStripeAccount(a.AccountID, late, "ready", "US", "bank", "9999", true); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatal(err)
			}
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			user, err := s.GetUserByAccountID(a.AccountID)
			if err != nil || user.StripeAccountID != a.Stripe {
				t.Fatalf("cancel restored overwritten Stripeaccount: %+v %v", user, err)
			}
			next := erasurefixture.PlanAndConfirm(t, s, a, now.Add(2*time.Minute), 0)
			if _, err := s.ScrubAccount(ctx, next.ID, now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			_, items, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, item := range items {
				if item.ExternalID == late && item.RequestID == next.ID {
					found = true
				}
				if item.RequestID == req.ID {
					t.Fatal("staging still owned by canceled request")
				}
			}
			if !found {
				t.Fatal("later scrub lost staged external object")
			}
		})
	}
}

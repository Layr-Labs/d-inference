package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureOutboxLeaseAndResult(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}

			rows, err := s.LeaseDueErasureOutbox(ctx, now, now, time.Minute, 10)
			if err != nil || len(rows) != 3 {
				t.Fatalf("lease = %d rows, %v; want 3", len(rows), err)
			}
			byTarget := map[store.ErasureTarget]store.ErasureOutboxWork{}
			for _, r := range rows {
				if r.AccountID != a.AccountID || r.RequestID != req.ID || r.ErasedAt.IsZero() {
					t.Fatalf("leased row = %+v", r)
				}
				byTarget[r.Target] = r
			}
			if again, _ := s.LeaseDueErasureOutbox(ctx, now, now, time.Minute, 10); len(again) != 0 {
				t.Fatalf("leased rows leased again: %d", len(again))
			}

			acct := byTarget[store.ErasureTargetStripeAccount]
			if acct.ExternalID != a.Stripe {
				t.Fatalf("stripe_account external id = %q", acct.ExternalID)
			}
			if err := s.SaveErasureOutboxResult(ctx, acct.ID, store.ErasureOutboxResult{LeaseGeneration: acct.LeaseGeneration, State: store.ErasureOutboxDone, NextAt: now}); err != nil {
				t.Fatal(err)
			}
			checkout := byTarget[store.ErasureTargetCheckoutSessions]
			later := now.Add(5 * time.Minute)
			since := now.Add(-time.Minute)
			split := &store.ErasureOutboxItem{ID: uniqueID("ob-split"), RequestID: req.ID, Target: store.ErasureTargetCheckoutSessions, ExternalID: "cs_missing", LastError: "not found"}
			if err := s.SaveErasureOutboxResult(ctx, checkout.ID, store.ErasureOutboxResult{
				LeaseGeneration: checkout.LeaseGeneration, State: store.ErasureOutboxPending, NextAt: later, ExternalID: checkout.ExternalID, StripeJobID: "prj_1",
				JobStatus: "validating", JobStatusSince: &since, JobGeneration: 2, Split: split,
			}); err != nil {
				t.Fatal(err)
			}
			logRow := byTarget[store.ErasureTargetErasureLog]
			if err := s.SaveErasureOutboxResult(ctx, logRow.ID, store.ErasureOutboxResult{LeaseGeneration: logRow.LeaseGeneration, State: store.ErasureOutboxManualAction, Attempts: 8, NextAt: now, LastError: "retries exhausted"}); err != nil {
				t.Fatal(err)
			}
			if err := s.SaveErasureOutboxResult(ctx, logRow.ID, store.ErasureOutboxResult{LeaseGeneration: logRow.LeaseGeneration, State: store.ErasureOutboxDone, NextAt: now}); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("result on a manual_action row: %v", err)
			}

			_, items, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			for _, it := range items {
				switch it.Target {
				case store.ErasureTargetStripeAccount:
					if it.State != store.ErasureOutboxDone || it.HasExternalID || it.ExternalID != "" || it.DoneAt == nil {
						t.Errorf("done row = %+v; the Stripe ID must be cleared", it)
					}
				case store.ErasureTargetCheckoutSessions:
					if it.ID == split.ID {
						if it.State != store.ErasureOutboxManualAction || it.ExternalID != "cs_missing" || it.LastError != "not found" {
							t.Errorf("split row = %+v", it)
						}
						continue
					}
					if it.State != store.ErasureOutboxPending || it.StripeJobID != "prj_1" || !it.HasStripeJob || !it.NextAt.Equal(later) ||
						it.ExternalID != a.Checkout || it.JobStatus != "validating" || it.JobGeneration != 2 || it.JobStatusSince == nil || !it.JobStatusSince.Equal(since) {
						t.Errorf("progress row = %+v", it)
					}
				case store.ErasureTargetErasureLog:
					if it.State != store.ErasureOutboxManualAction || it.Attempts != 8 || it.LastError == "" {
						t.Errorf("manual row = %+v", it)
					}
				}
			}
			// The progress row is due again after its next_at.
			if due, _ := s.LeaseDueErasureOutbox(ctx, later, later, time.Minute, 10); len(due) != 1 || due[0].StripeJobID != "prj_1" || due[0].JobGeneration != 2 {
				t.Fatalf("lease after next_at = %+v", due)
			}
		})
	}
}

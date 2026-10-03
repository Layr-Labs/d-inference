package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestErasureOutboxLeaseAndResult(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := seedErasureAccount(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			req := planAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}

			rows, err := s.LeaseDueErasureOutbox(ctx, now, time.Minute, 10)
			if err != nil || len(rows) != 3 {
				t.Fatalf("lease = %d rows, %v; want 3", len(rows), err)
			}
			byTarget := map[ErasureTarget]ErasureOutboxWork{}
			for _, r := range rows {
				if r.AccountID != a.AccountID || r.RequestID != req.ID || r.ErasedAt.IsZero() {
					t.Fatalf("leased row = %+v", r)
				}
				byTarget[r.Target] = r
			}
			if again, _ := s.LeaseDueErasureOutbox(ctx, now, time.Minute, 10); len(again) != 0 {
				t.Fatalf("leased rows leased again: %d", len(again))
			}

			acct := byTarget[ErasureTargetStripeAccount]
			if acct.ExternalID != a.Stripe {
				t.Fatalf("stripe_account external id = %q", acct.ExternalID)
			}
			if err := s.SaveErasureOutboxResult(ctx, acct.ID, ErasureOutboxResult{State: ErasureOutboxDone, NextAt: now}); err != nil {
				t.Fatal(err)
			}
			checkout := byTarget[ErasureTargetCheckoutSessions]
			later := now.Add(5 * time.Minute)
			if err := s.SaveErasureOutboxResult(ctx, checkout.ID, ErasureOutboxResult{State: ErasureOutboxPending, NextAt: later, StripeJobID: "prj_1"}); err != nil {
				t.Fatal(err)
			}
			logRow := byTarget[ErasureTargetErasureLog]
			if err := s.SaveErasureOutboxResult(ctx, logRow.ID, ErasureOutboxResult{State: ErasureOutboxManualAction, Attempts: 8, NextAt: now, LastError: "retries exhausted"}); err != nil {
				t.Fatal(err)
			}
			if err := s.SaveErasureOutboxResult(ctx, logRow.ID, ErasureOutboxResult{State: ErasureOutboxDone, NextAt: now}); !errors.Is(err, ErrErasureConflict) {
				t.Fatalf("result on a manual_action row: %v", err)
			}

			_, items, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			for _, it := range items {
				switch it.Target {
				case ErasureTargetStripeAccount:
					if it.State != ErasureOutboxDone || it.HasExternalID || it.ExternalID != "" || it.DoneAt == nil {
						t.Errorf("done row = %+v; the Stripe ID must be cleared", it)
					}
				case ErasureTargetCheckoutSessions:
					if it.State != ErasureOutboxPending || it.StripeJobID != "prj_1" || !it.HasStripeJob || !it.NextAt.Equal(later) {
						t.Errorf("progress row = %+v", it)
					}
				case ErasureTargetErasureLog:
					if it.State != ErasureOutboxManualAction || it.Attempts != 8 || it.LastError == "" {
						t.Errorf("manual row = %+v", it)
					}
				}
			}
			// The progress row is due again after its next_at.
			if due, _ := s.LeaseDueErasureOutbox(ctx, later, time.Minute, 10); len(due) != 1 || due[0].StripeJobID != "prj_1" {
				t.Fatalf("lease after next_at = %+v", due)
			}
		})
	}
}

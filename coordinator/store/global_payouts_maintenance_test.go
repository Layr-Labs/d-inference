package store

import (
	"errors"
	"testing"
	"time"
)

func TestGlobalPayoutQuotePruningPreservesConfirmedFunds(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			pending := payoutFixture(t, s, g, "prune-pending", "prune-pending")
			_, err := g.BeginGlobalPayout(pending.AccountID, pending.ID, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			posted := payoutFixture(t, s, g, "prune-posted", "prune-posted")
			_, err = g.BeginGlobalPayout(posted.AccountID, posted.ID, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if err = g.ApplyGlobalPayout(posted.ID, GlobalPayoutResult{Status: "posted", ExternalID: "obp_prune"}, time.Now()); err != nil {
				t.Fatal(err)
			}
			expired := payoutFixture(t, s, g, "prune-expired", "prune-expired")
			another := expired
			another.ID = "prune-expired-2"
			if err = g.CreateGlobalPayoutQuote(another); err != nil {
				t.Fatal(err)
			}
			live := expired
			live.ID = "prune-live"
			live.ExpiresAt = time.Now().Add(time.Hour)
			if err = g.CreateGlobalPayoutQuote(live); err != nil {
				t.Fatal(err)
			}
			cutoff := time.Now().Add(2 * time.Minute)
			if count, err := g.PruneExpiredGlobalPayoutQuotes(cutoff, 1); err != nil || count != 1 {
				t.Fatalf("bounded prune: %d %v", count, err)
			}
			if count, err := g.PruneExpiredGlobalPayoutQuotes(cutoff, 1000); err != nil || count != 1 {
				t.Fatalf("remaining expired quote: %d %v", count, err)
			}
			for _, p := range []GlobalPayout{pending, posted, live} {
				if _, err = g.GetGlobalPayout(p.ID); err != nil {
					t.Fatalf("retained row %s: %v", p.ID, err)
				}
			}
			if _, err = g.GetGlobalPayout(expired.ID); !errors.Is(err, ErrNotFound) {
				t.Fatal("expired unconfirmed quote retained")
			}
			if s.GetWithdrawableBalance(pending.AccountID) != 2_000_000 || s.GetWithdrawableBalance(expired.AccountID) != 10_000_000 {
				t.Fatal("cleanup moved funds")
			}
		})
	}
}

func TestGlobalPayoutRejectionFencesFutureDispatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "rejection", "rejection")
			now := time.Now()
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, now); err != nil {
				t.Fatal(err)
			}
			if ok, err := g.ClaimGlobalPayout(p.ID, now); err != nil || !ok {
				t.Fatal(err)
			}
			if err := g.RecordGlobalPayoutRejection(p.ID, 1, "forbidden"); err != nil {
				t.Fatal(err)
			}
			if ok, err := g.ClaimGlobalPayout(p.ID, now.Add(2*time.Minute)); err != nil || !ok {
				t.Fatal(err)
			}
			got, err := g.GetGlobalPayout(p.ID)
			if err != nil || got.DispatchAttempts != 1 || got.Rejection == nil {
				t.Fatalf("rejection lost or dispatch advanced: %+v %v", got, err)
			}
			for range 2 {
				if err = g.ApplyGlobalPayout(p.ID, GlobalPayoutResult{Status: "failed", FailureCode: got.Rejection.Code}, time.Now()); err != nil {
					t.Fatal(err)
				}
			}
			if s.GetWithdrawableBalance(p.AccountID) != 10_000_000 {
				t.Fatal("rejection not refunded exactly once")
			}
			ambiguous := payoutFixture(t, s, g, "ambiguous", "ambiguous")
			_, _ = g.BeginGlobalPayout(ambiguous.AccountID, ambiguous.ID, now)
			_, _ = g.ClaimGlobalPayout(ambiguous.ID, now)
			_, _ = g.ClaimGlobalPayout(ambiguous.ID, now.Add(2*time.Minute))
			if err = g.RecordGlobalPayoutRejection(ambiguous.ID, 1, "forbidden"); !errors.Is(err, ErrPayoutConflict) {
				t.Fatal("stale rejection accepted after a subsequent send")
			}
		})
	}
}

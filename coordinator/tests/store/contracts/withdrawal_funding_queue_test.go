package store_test

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestStripeFundingQueueClaimsAndUnknownOutcome(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account, id := "queue-connect", "queue-connect-1"
			if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
				t.Fatal(err)
			}
			if err := s.CreditWithdrawable(account, 10_000_000, store.LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			wd := &store.StripeWithdrawal{ID: id, AccountID: account, StripeAccountID: "acct_q", AmountMicroUSD: 8_000_000, NetMicroUSD: 8_000_000, Method: "standard", Status: "pending"}
			if err := s.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:"+id); err != nil {
				t.Fatal(err)
			}
			q, ok := store.As[store.StripeWithdrawalQueueStore](s)
			if !ok {
				t.Fatal("missing queue store")
			}
			if err := q.QueueStripeWithdrawal(id, 0); err != nil {
				t.Fatal(err)
			}
			now := time.Now()
			rows, err := q.ListStripeWithdrawalQueue(now, 200)
			if err != nil || len(rows) != 1 {
				t.Fatalf("queue %+v %v", rows, err)
			}
			plan, err := s.PlanAccountErasure(context.Background(), account, nil)
			if err != nil || plan.OpenWithdrawals != 1 {
				t.Fatalf("queued withdrawal lost during erasure: %+v %v", plan, err)
			}
			var claims atomic.Int32
			var wg sync.WaitGroup
			for range 12 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					w, err := q.ClaimStripeWithdrawal(id, now)
					if err != nil {
						t.Error(err)
					}
					if w != nil {
						claims.Add(1)
					}
				}()
			}
			wg.Wait()
			if claims.Load() != 1 {
				t.Fatalf("dispatchers claimed %d times", claims.Load())
			}
			got, err := s.GetStripeWithdrawal(id)
			if err != nil || got.TransferAttempt != 1 || got.TransferDispatchAttempts != 1 {
				t.Fatalf("claim %+v %v", got, err)
			}
			retry, err := q.ClaimStripeWithdrawal(id, now.Add(6*time.Minute))
			if err != nil || retry == nil || retry.TransferAttempt != 1 || retry.TransferDispatchAttempts != 2 {
				t.Fatalf("unknown retry changed key: %+v %v", retry, err)
			}
			if err := q.QueueStripeWithdrawal(id, 1); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("later rejection queued unknown original send: %v", err)
			}
			if retry, err := q.ClaimStripeWithdrawal(id, now.Add(13*time.Hour)); err != nil || retry != nil {
				t.Fatalf("replayed past idempotency horizon: %+v %v", retry, err)
			}
			if b, w := s.GetBalanceWithWithdrawable(account); b != 2_000_000 || w != b {
				t.Fatalf("queue spent/refunded twice: %d %d", b, w)
			}
		})
	}
}

func TestGlobalFundingQueueSurvivesQuoteExpiryAndFencesClaims(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := store.As[store.GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "queue-global", "queue-global-1")
			now := time.Now()
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, now); err != nil {
				t.Fatal(err)
			}
			if ok, err := g.ClaimGlobalPayout(p.ID, now); err != nil || ok == nil {
				t.Fatal(ok, err)
			}
			claimed, _ := g.GetGlobalPayout(p.ID)
			if claimed.DispatchAttempts != 0 || !claimed.DispatchStartedAt.IsZero() {
				t.Fatalf("lease claim consumed send: %+v", claimed)
			}
			if err := g.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{Status: "queued", FailureCode: store.WithdrawalFundingReason, ExpectedLease: claimed.LeaseUntil}, now); err != nil {
				t.Fatal(err)
			}
			later := now.Add(48 * time.Hour)
			rows, err := g.ListGlobalPayoutsToReconcile(later, 200)
			if err != nil || len(rows) != 1 {
				t.Fatal(rows, err)
			}
			plan, err := s.PlanAccountErasure(context.Background(), p.AccountID, nil)
			if err != nil || plan.OpenWithdrawals != 1 {
				t.Fatalf("queue erased: %+v %v", plan, err)
			}
			if ok, err := g.ClaimGlobalPayout(p.ID, later); err != nil || ok == nil {
				t.Fatal(ok, err)
			}
			current, _ := g.GetGlobalPayout(p.ID)
			if current.DispatchAttempts != 0 || current.FundingGeneration != 1 {
				t.Fatalf("funding wait burned dispatch attempt: %+v", current)
			}
			if err := g.StartUnsentGlobalPayout(p.ID, claimed.LeaseUntil, p.Request, nil, 64000, later.Add(time.Minute), later); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("expired worker refreshed request: %v", err)
			}
			if err := g.RecordGlobalPayoutRejection(p.ID, 0, "forbidden", claimed.LeaseUntil); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("expired worker persisted rejection: %v", err)
			}
			if err := g.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{Status: "queued", ExpectedLease: claimed.LeaseUntil}, later); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("expired worker released newer claim: %v", err)
			}
			if err := g.StartUnsentGlobalPayout(p.ID, current.LeaseUntil, p.Request, nil, 64000, later.Add(time.Minute), later); err != nil {
				t.Fatal(err)
			}
			started, _ := g.GetGlobalPayout(p.ID)
			if started.Status != "pending" || started.DispatchAttempts != 1 || !started.DispatchStartedAt.Equal(later) {
				t.Fatalf("fresh dispatch horizon %+v", started)
			}
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, later); err != nil {
				t.Fatal(err)
			}
			if b, w := s.GetBalanceWithWithdrawable(p.AccountID); b != 2_000_000 || w != b {
				t.Fatalf("reconfirmation debited queue twice %d %d", b, w)
			}
		})
	}
}

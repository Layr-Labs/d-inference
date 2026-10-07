package store_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func queuedStripeFixture(t *testing.T, s store.Store, account, id string) (*store.StripeWithdrawal, store.StripeWithdrawalQueueStore) {
	t.Helper()
	w := &store.StripeWithdrawal{
		ID: id, AccountID: account, StripeAccountID: "acct_queue", AmountMicroUSD: 1_000_000,
		NetMicroUSD: 1_000_000, Method: "standard", Status: "pending", TransferStartedAt: time.Now().Add(-time.Hour),
	}
	if err := s.CreateStripeWithdrawalWithDebit(w, store.LedgerStripePayout, "stripe_withdraw:"+id); err != nil {
		t.Fatal(err)
	}
	q, ok := store.As[store.StripeWithdrawalQueueStore](s)
	if !ok {
		t.Fatal("missing queue store")
	}
	if err := q.QueueStripeWithdrawal(id, 0); err != nil {
		t.Fatal(err)
	}
	return w, q
}

func TestStripeFundingQueueDeferralAllowsProgressBeyondBatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			const account = "queue-fairness"
			if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
				t.Fatal(err)
			}
			if err := s.CreditWithdrawable(account, 201_000_000, store.LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			var q store.StripeWithdrawalQueueStore
			for i := range 201 {
				_, q = queuedStripeFixture(t, s, account, fmt.Sprintf("queue-fair-%03d", i))
			}
			now := time.Now().Add(time.Millisecond).Truncate(time.Microsecond)
			rows, err := q.ListStripeWithdrawalQueue(now, 200)
			if err != nil || len(rows) != 200 {
				t.Fatalf("first batch = %d, %v", len(rows), err)
			}
			for _, row := range rows {
				if err := q.DeferStripeWithdrawal(row.ID, row.TransferAttempt, now); err != nil {
					t.Fatal(err)
				}
				got, err := s.GetStripeWithdrawal(row.ID)
				if err != nil || got.Status != "queued" || got.TransferAttempt != row.TransferAttempt || got.TransferDispatchAttempts != row.TransferDispatchAttempts || !got.TransferStartedAt.Equal(row.TransferStartedAt) || !got.UpdatedAt.Equal(now) || !got.TransferLeaseUntil.Equal(now.Add(5*time.Minute)) {
					t.Fatalf("preflight consumed a send or lost retry state: %+v, %v", got, err)
				}
			}
			next, err := q.ListStripeWithdrawalQueue(now, 200)
			if err != nil || len(next) != 1 || next[0].ID != "queue-fair-200" {
				t.Fatalf("older unavailable rows starved the newer withdrawal: %+v, %v", next, err)
			}
			if claimed, err := q.ClaimStripeWithdrawal(next[0].ID, now); err != nil || claimed == nil {
				t.Fatalf("newer withdrawal could not dispatch: %+v, %v", claimed, err)
			}
			if err := q.DeferStripeWithdrawal(next[0].ID, next[0].TransferAttempt, now.Add(6*time.Minute)); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("stale preflight deferred a claimed send: %v", err)
			}
			if ready, err := q.ListStripeWithdrawalQueue(now.Add(5*time.Minute), 200); err != nil || len(ready) != 200 {
				t.Fatalf("deferred withdrawals did not become eligible: %d, %v", len(ready), err)
			}
			if b, w := s.GetBalanceWithWithdrawable(account); b != 0 || w != 0 {
				t.Fatalf("deferral moved reserved earnings: %d, %d", b, w)
			}
		})
	}
}

func TestStripeFundingQueueUnsentRejectionFencesClaimsAndRefundsOnce(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			const account = "queue-unsent-rejection"
			if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
				t.Fatal(err)
			}
			if err := s.CreditWithdrawable(account, 3_000_000, store.LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			_, q := queuedStripeFixture(t, s, account, "queue-removed")
			before, err := s.GetStripeWithdrawal("queue-removed")
			if err != nil {
				t.Fatal(err)
			}
			now := time.Now().Add(time.Millisecond).Truncate(time.Microsecond)
			if err := q.RejectQueuedStripeWithdrawal(before.ID, before.TransferAttempt+1, now, "queued_destination_removed"); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("stale generation persisted rejection: %v", err)
			}
			if err := q.RejectQueuedStripeWithdrawal(before.ID, before.TransferAttempt, now, "queued_destination_removed"); err != nil {
				t.Fatal(err)
			}
			rejected, err := s.GetStripeWithdrawal(before.ID)
			if err != nil || !store.StripeRefundRecoverable(rejected) || rejected.TransferAttempt != before.TransferAttempt || rejected.TransferDispatchAttempts != before.TransferDispatchAttempts || !rejected.TransferStartedAt.Equal(before.TransferStartedAt) {
				t.Fatalf("known unsent rejection consumed dispatch: %+v, %v", rejected, err)
			}
			if claimed, err := q.ClaimStripeWithdrawal(before.ID, now); err != nil || claimed != nil {
				t.Fatalf("claimed a durable rejection: %+v, %v", claimed, err)
			}
			settlement, _ := store.As[store.StripeSettlementStore](s)
			for i := range 2 {
				applied, err := settlement.RefundRejectedStripeWithdrawal(before.ID)
				if err != nil || applied != (i == 0) {
					t.Fatalf("refund %d applied=%v, %v", i, applied, err)
				}
			}
			_, q = queuedStripeFixture(t, s, account, "queue-unknown")
			if claimed, err := q.ClaimStripeWithdrawal("queue-unknown", now); err != nil || claimed == nil {
				t.Fatalf("claim: %+v, %v", claimed, err)
			}
			for _, attempt := range []int{0, 1} {
				if err := q.RejectQueuedStripeWithdrawal("queue-unknown", attempt, now.Add(6*time.Minute), "queued_destination_removed"); !errors.Is(err, store.ErrPayoutConflict) {
					t.Fatalf("account absence rejected unknown send: attempt=%d, %v", attempt, err)
				}
				if err := q.DeferStripeWithdrawal("queue-unknown", attempt, now.Add(6*time.Minute)); !errors.Is(err, store.ErrPayoutConflict) {
					t.Fatalf("preflight deferred unknown send: attempt=%d, %v", attempt, err)
				}
			}
			retried, err := q.ClaimStripeWithdrawal("queue-unknown", now.Add(6*time.Minute))
			if err != nil || retried == nil || retried.TransferAttempt != 1 || retried.TransferDispatchAttempts != 2 || !retried.TransferStartedAt.Equal(now) {
				t.Fatalf("unknown send lost its key/horizon: %+v, %v", retried, err)
			}
			if err := q.QueueStripeWithdrawal(retried.ID, retried.TransferAttempt); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("later account rejection queued an unknown send: %v", err)
			}
			if _, err := settlement.RefundRejectedStripeWithdrawal(retried.ID); !errors.Is(err, store.ErrPayoutConflict) {
				t.Fatalf("account absence refunded an unknown send: %v", err)
			}
			if b, w := s.GetBalanceWithWithdrawable(account); b != 2_000_000 || w != b {
				t.Fatalf("unsafe refund or repeated debit: %d, %d", b, w)
			}
		})
	}
}

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

package store

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func payoutFixture(t *testing.T, s Store, g GlobalPayoutStore, account, id string) GlobalPayout {
	t.Helper()
	if err := s.CreateUser(&User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(account, 10_000_000, LedgerPayout, "earn-"+account); err != nil {
		t.Fatal(err)
	}
	r := GlobalRecipient{ID: "generation-" + id, AccountID: account, Country: "IN", RecipientID: "acct_" + id, PayoutMethodID: "pm_" + id, Ready: true}
	if _, err := g.PrepareGlobalRecipient(r); err != nil {
		t.Fatal(err)
	}
	p := GlobalPayout{ID: id, AccountID: account, RecipientGeneration: r.ID, RecipientID: r.RecipientID, PayoutMethodID: r.PayoutMethodID, Country: "IN", AmountMicroUSD: 8_000_000, DestinationAmount: 64000, Currency: "inr", Request: []byte(`{"amount":{"value":800,"currency":"usd"}}`), Status: "quoted", CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute)}
	if err := g.CreateGlobalPayoutQuote(p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestGlobalPayoutLedgerLifecycle(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, ok := As[GlobalPayoutStore](s)
			if !ok {
				t.Fatal("missing payout store")
			}
			p := payoutFixture(t, s, g, "gp-lifecycle", "gp-1")
			var wg sync.WaitGroup
			for range 12 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, time.Now()); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if b, w := s.GetBalanceWithWithdrawable(p.AccountID); b != 2_000_000 || w != b {
				t.Fatalf("repeated confirm debited twice: %d/%d", b, w)
			}
			if err := g.ApplyGlobalPayout(p.ID, GlobalPayoutResult{Status: "posted", ExternalID: "obp_gp1"}, time.Now()); err != nil {
				t.Fatal(err)
			}
			if err := g.ApplyGlobalPayout(p.ID, GlobalPayoutResult{Status: "processing", ExternalID: "obp_gp1"}, time.Now()); err != nil {
				t.Fatal(err)
			}
			got, _ := g.GetGlobalPayout(p.ID)
			if got.Status != "posted" {
				t.Fatal("stale status regressed posted payout")
			}
			for range 12 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if err := g.ApplyGlobalPayout(p.ID, GlobalPayoutResult{Status: "returned", ExternalID: "obp_gp1"}, time.Now()); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if err := g.ApplyGlobalPayout(p.ID, GlobalPayoutResult{Status: "posted", ExternalID: "obp_gp1"}, time.Now()); err != nil {
				t.Fatal(err)
			}
			got, _ = g.GetGlobalPayout(p.ID)
			if got.Status != "returned" || !got.Refunded {
				t.Fatalf("refunded payout reopened: %+v", got)
			}
			if b, w := s.GetBalanceWithWithdrawable(p.AccountID); b != 10_000_000 || w != b {
				t.Fatalf("refund not exactly once: %d/%d", b, w)
			}
		})
	}
}

func TestGlobalPayoutCompetesWithConnect(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "gp-race", "gp-race-1")
			var successes atomic.Int32
			var wg sync.WaitGroup
			start := make(chan struct{})
			wg.Add(2)
			go func() {
				defer wg.Done()
				<-start
				_, err := g.BeginGlobalPayout(p.AccountID, p.ID, time.Now())
				if err == nil {
					successes.Add(1)
				} else if !errors.Is(err, ErrInsufficientBalance) {
					t.Error(err)
				}
			}()
			go func() {
				defer wg.Done()
				<-start
				err := s.CreateStripeWithdrawalWithDebit(&StripeWithdrawal{ID: "connect-race", AccountID: p.AccountID, StripeAccountID: "acct_legacy", AmountMicroUSD: 8_000_000, NetMicroUSD: 8_000_000, Status: "pending", Method: "standard"}, LedgerStripePayout, "connect-race")
				if err == nil {
					successes.Add(1)
				} else if !errors.Is(err, ErrInsufficientBalance) {
					t.Error(err)
				}
			}()
			close(start)
			wg.Wait()
			if successes.Load() != 1 {
				t.Fatalf("both payout rails spent the same funds: %d", successes.Load())
			}
			if b, w := s.GetBalanceWithWithdrawable(p.AccountID); b != 2_000_000 || w != b {
				t.Fatalf("wrong balance: %d/%d", b, w)
			}
		})
	}
}

func TestGlobalPayoutQuoteAuthorizationAndDestination(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "gp-owner", "gp-owner-1")
			if _, err := g.BeginGlobalPayout("someone-else", p.ID, time.Now()); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cross-account quote: %v", err)
			}
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, p.ExpiresAt); !errors.Is(err, ErrPayoutQuoteExpired) {
				t.Fatalf("expired quote: %v", err)
			}
			r, _ := g.GetGlobalRecipient(p.AccountID)
			r.PayoutMethodID = "pm_changed"
			if err := g.SaveGlobalRecipient(*r); err != nil {
				t.Fatal(err)
			}
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, time.Now()); !errors.Is(err, ErrPayoutConflict) {
				t.Fatalf("changed destination: %v", err)
			}
			if b := s.GetWithdrawableBalance(p.AccountID); b != 10_000_000 {
				t.Fatalf("invalid confirmation debited: %d", b)
			}
			if err := g.RemoveGlobalRecipient(p.AccountID); err != nil {
				t.Fatal(err)
			}
			if err := g.SaveGlobalRecipient(*r); !errors.Is(err, ErrPayoutConflict) {
				t.Fatalf("late onboarding resurrected an unlinked recipient: %v", err)
			}
		})
	}
}

package store

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
)

func TestApplyStripeDepositExactlyOnce(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("stripe-account")
			sessionID := uniqueID("billing-session")
			checkoutID := uniqueID("checkout-session")
			eventID := uniqueID("stripe-event")
			session := &BillingSession{
				ID: sessionID, AccountID: accountID, PaymentMethod: "stripe",
				Currency: "usd", AmountMicroUSD: 5_000_000,
				ExternalID: checkoutID, Status: "pending",
			}
			if err := backend.CreateBillingSession(session); err != nil {
				t.Fatal(err)
			}

			first, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 5_000_000)
			if err != nil {
				t.Fatal(err)
			}
			if !first.Applied || first.Session.AccountID != accountID {
				t.Fatalf("first result = %+v", first)
			}
			replay, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 5_000_000)
			if err != nil {
				t.Fatal(err)
			}
			if replay.Applied {
				t.Fatal("same event replay applied money twice")
			}
			secondEvent, err := backend.ApplyStripeDeposit(uniqueID("stripe-event"), sessionID, checkoutID, "usd", 5_000_000)
			if err != nil {
				t.Fatal(err)
			}
			if secondEvent.Applied {
				t.Fatal("second event for one Checkout Session applied money twice")
			}
			if balance := backend.GetBalance(accountID); balance != 5_000_000 {
				t.Fatalf("balance = %d, want 5000000", balance)
			}
			if withdrawable := backend.GetWithdrawableBalance(accountID); withdrawable != 0 {
				t.Fatalf("Stripe deposit became withdrawable: %d", withdrawable)
			}
			history := backend.LedgerHistory(accountID)
			if len(history) != 1 || history[0].Type != LedgerStripeDeposit {
				t.Fatalf("ledger history = %+v, want one Stripe deposit", history)
			}
		})
	}
}

func TestApplyStripeDepositConcurrentDelivery(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("concurrent-account")
			sessionID := uniqueID("concurrent-session")
			checkoutID := uniqueID("concurrent-checkout")
			eventID := uniqueID("concurrent-event")
			if err := backend.CreateBillingSession(&BillingSession{
				ID: sessionID, AccountID: accountID, PaymentMethod: "stripe",
				Currency: "usd", AmountMicroUSD: 750_000, ExternalID: checkoutID,
				Status: "pending",
			}); err != nil {
				t.Fatal(err)
			}

			var applied atomic.Int32
			errs := make(chan error, 16)
			var workers sync.WaitGroup
			for range 16 {
				workers.Add(1)
				go func() {
					defer workers.Done()
					result, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 750_000)
					if err == nil && result.Applied {
						applied.Add(1)
					}
					errs <- err
				}()
			}
			workers.Wait()
			close(errs)
			for err := range errs {
				if err != nil {
					t.Errorf("concurrent delivery: %v", err)
				}
			}
			if got := applied.Load(); got != 1 {
				t.Fatalf("applied deliveries = %d, want 1", got)
			}
			if balance := backend.GetBalance(accountID); balance != 750_000 {
				t.Fatalf("balance = %d, want 750000", balance)
			}
		})
	}
}

func TestApplyStripeDepositRejectsMismatchesWithoutCredit(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("mismatch-account")
			sessionID := uniqueID("mismatch-session")
			checkoutID := uniqueID("mismatch-checkout")
			eventID := uniqueID("mismatch-event")
			if err := backend.CreateBillingSession(&BillingSession{
				ID: sessionID, AccountID: accountID, PaymentMethod: "stripe",
				Currency: "usd", AmountMicroUSD: 500_000, ExternalID: checkoutID,
				Status: "pending",
			}); err != nil {
				t.Fatal(err)
			}

			if _, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 600_000); !errors.Is(err, ErrStripeDepositMismatch) {
				t.Fatalf("amount mismatch error = %v", err)
			}
			if balance := backend.GetBalance(accountID); balance != 0 {
				t.Fatalf("mismatched event credited %d", balance)
			}
			stored, err := backend.GetBillingSession(sessionID)
			if err != nil {
				t.Fatal(err)
			}
			if stored.Status != "pending" {
				t.Fatalf("mismatched session status = %q, want pending", stored.Status)
			}
			if _, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 600_000); !errors.Is(err, ErrStripeDepositMismatch) {
				t.Fatalf("rejected replay error = %v", err)
			}
			if _, err := backend.ApplyStripeDeposit(uniqueID("unknown-event"), "", uniqueID("unknown-checkout"), "usd", 500_000); !errors.Is(err, ErrStripeDepositMismatch) {
				t.Fatalf("unknown session error = %v", err)
			}
		})
	}
}

func TestStripeDepositEventIdentityConflict(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			sessionID := uniqueID("conflict-session")
			checkoutID := uniqueID("conflict-checkout")
			eventID := uniqueID("conflict-event")
			if err := backend.CreateBillingSession(&BillingSession{
				ID: sessionID, AccountID: uniqueID("conflict-account"), PaymentMethod: "stripe",
				Currency: "usd", AmountMicroUSD: 500_000, ExternalID: checkoutID,
				Status: "pending",
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := backend.ApplyStripeDeposit(eventID, sessionID, checkoutID, "usd", 500_000); err != nil {
				t.Fatal(err)
			}
			if _, err := backend.ApplyStripeDeposit(eventID, sessionID, uniqueID("other-checkout"), "usd", 500_000); !errors.Is(err, ErrStripeDepositConflict) {
				t.Fatalf("identity conflict error = %v", err)
			}
			if _, err := backend.ApplyStripeDeposit(uniqueID("other-event"), sessionID, checkoutID, "usd", 600_000); !errors.Is(err, ErrStripeDepositConflict) {
				t.Fatalf("replayed amount conflict error = %v", err)
			}
		})
	}
}

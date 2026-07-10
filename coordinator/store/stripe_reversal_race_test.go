package store

import (
	"sync"
	"testing"
	"time"
)

func TestPayoutPaidAndTransferReversalSerializeWithoutDoublePayment(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for iteration := range 10 {
				accountID := uniqueID("reversal-account")
				withdrawalID := uniqueID("reversal-withdrawal")
				payoutID := uniqueID("reversal-payout")
				if err := backend.CreditWithdrawable(accountID, 100_000, LedgerPayout, "earning"); err != nil {
					t.Fatal(err)
				}
				if err := backend.DebitWithdrawable(accountID, 100_000, LedgerStripePayout, "withdraw"); err != nil {
					t.Fatal(err)
				}
				if err := backend.CreateStripeWithdrawal(&StripeWithdrawal{
					ID: withdrawalID, AccountID: accountID, StripeAccountID: "acct",
					PayoutID: payoutID, AmountMicroUSD: 100_000, FeeMicroUSD: 10_000,
					NetMicroUSD: 90_000, Method: "instant", Status: "transferred",
					CreatedAt: time.Now(), UpdatedAt: time.Now(),
				}); err != nil {
					t.Fatal(err)
				}
				var workers sync.WaitGroup
				workers.Add(2)
				errs := make(chan error, 2)
				go func() {
					defer workers.Done()
					_, err := backend.MarkStripeWithdrawalPaid(withdrawalID, payoutID, "")
					errs <- err
				}()
				go func() {
					defer workers.Done()
					_, _, err := backend.RefundStripeWithdrawalOnReversal(withdrawalID)
					errs <- err
				}()
				workers.Wait()
				close(errs)
				for err := range errs {
					if err != nil {
						t.Errorf("iteration %d: %v", iteration, err)
					}
				}
				withdrawal, err := backend.GetStripeWithdrawal(withdrawalID)
				if err != nil {
					t.Fatal(err)
				}
				balance := backend.GetBalance(accountID)
				switch withdrawal.Status {
				case "paid":
					if withdrawal.Refunded || balance != 0 {
						t.Fatalf("paid row also refunded: %+v balance=%d", withdrawal, balance)
					}
				case "review_pending":
					if withdrawal.Refunded || balance != 0 {
						t.Fatalf("review row also refunded: %+v balance=%d", withdrawal, balance)
					}
				case "failed":
					if !withdrawal.Refunded || balance != 100_000 {
						t.Fatalf("reversed row not restored exactly: %+v balance=%d", withdrawal, balance)
					}
				default:
					t.Fatalf("unexpected terminal race status %q", withdrawal.Status)
				}
			}
		})
	}
}

func TestSweepPaidAndFailureTombstoneCannotLeaveRowsPaid(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for range 10 {
				accountID := uniqueID("sweep-account")
				withdrawalID := uniqueID("sweep-withdrawal")
				sweepID := uniqueID("sweep-payout")
				if err := backend.CreateStripeWithdrawal(&StripeWithdrawal{
					ID: withdrawalID, AccountID: accountID, StripeAccountID: "acct",
					AmountMicroUSD: 100_000, NetMicroUSD: 100_000,
					Method: "standard", Status: "transferred",
					CreatedAt: time.Now(), UpdatedAt: time.Now(),
				}); err != nil {
					t.Fatal(err)
				}
				reason := "sweep failed"
				var workers sync.WaitGroup
				workers.Add(2)
				errs := make(chan error, 2)
				go func() {
					defer workers.Done()
					_, err := backend.MarkStripeWithdrawalPaid(withdrawalID, "", sweepID)
					errs <- err
				}()
				go func() {
					defer workers.Done()
					if err := backend.RecordStripeSweepFailure(sweepID, reason); err != nil {
						errs <- err
						return
					}
					_, err := backend.ReopenStripeWithdrawalAfterSweepFailure(
						withdrawalID, sweepID, reason,
					)
					errs <- err
				}()
				workers.Wait()
				close(errs)
				for err := range errs {
					if err != nil {
						t.Error(err)
					}
				}
				withdrawal, err := backend.GetStripeWithdrawal(withdrawalID)
				if err != nil {
					t.Fatal(err)
				}
				if withdrawal.Status != "transferred" || withdrawal.Refunded {
					t.Fatalf("failed sweep left unsafe row: %+v", withdrawal)
				}
			}
		})
	}
}

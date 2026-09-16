package postgres

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLedgerCreditOnceAcrossConcurrentHandles(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			handles := []contracts.Store{backend}
			if pg, ok := backend.(*Store); ok {
				// A second independent pool proves that idempotency is enforced
				// by the database, not by a mutex in one store object.
				pool, err := pgxpool.NewWithConfig(t.Context(), pg.pool.Config())
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(pool.Close)
				handles = append(handles, &Store{pool: pool})
			}
			for _, withdrawable := range []bool{false, true} {
				label := "deposit"
				entryType := contracts.LedgerStripeDeposit
				if withdrawable {
					label, entryType = "refund", contracts.LedgerRefund
				}
				t.Run(label, func(t *testing.T) {
					accountID, reference := uniqueID("credit-once"), "event-reference"
					if err := backend.CreditWithdrawable(accountID, 50, contracts.LedgerPayout, "prior-earnings"); err != nil {
						t.Fatal(err)
					}
					type result struct {
						applied bool
						err     error
					}
					const deliveries = 24
					start, results := make(chan struct{}), make(chan result, deliveries)
					for i := range deliveries {
						handle := handles[i%len(handles)]
						go func() {
							<-start
							credit := handle.CreditOnce
							if withdrawable {
								credit = handle.CreditWithdrawableOnce
							}
							applied, err := credit(accountID, 100, entryType, reference)
							results <- result{applied, err}
						}()
					}
					close(start)
					applied := 0
					for range deliveries {
						select {
						case r := <-results:
							if r.err != nil {
								t.Fatal(r.err)
							}
							if r.applied {
								applied++
							}
						case <-time.After(10 * time.Second):
							t.Fatal("concurrent credit delivery did not finish")
						}
					}
					if applied != 1 {
						t.Fatalf("applied deliveries = %d, want 1", applied)
					}
					wantWithdrawable := int64(50)
					if withdrawable {
						wantWithdrawable = 150
					}
					balance, earned := backend.GetBalanceWithWithdrawable(accountID)
					if balance != 150 || earned != wantWithdrawable {
						t.Errorf("balances = (%d, %d), want (150, %d)", balance, earned, wantWithdrawable)
					}
					entries := backend.LedgerHistory(accountID)
					if len(entries) != 2 {
						t.Fatalf("ledger rows = %d, want prior earnings plus one credit", len(entries))
					}
					matches := 0
					for _, entry := range entries {
						if entry.Type == entryType && entry.Reference == reference && entry.AmountMicroUSD == 100 {
							matches++
						}
						if entry.BalanceAfter != 50 && entry.BalanceAfter != 150 {
							t.Errorf("unexpected ledger balance: %+v", entry)
						}
					}
					if matches != 1 {
						t.Errorf("matching credit rows = %d, want 1", matches)
					}
				})
			}
		})
	}
}

func TestCreditOnceRecognizesPriorLedgerAndIndependentIdentities(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID, reference := uniqueID("legacy-credit"), "stripe:prior-checkout"
			if err := backend.Credit(accountID, 100, contracts.LedgerStripeDeposit, reference); err != nil {
				t.Fatal(err)
			}
			if applied, err := backend.CreditOnce(accountID, 100, contracts.LedgerStripeDeposit, reference); err != nil || applied {
				t.Fatalf("prior ledger replay applied=%t error=%v", applied, err)
			}
			if balance := backend.GetBalance(accountID); balance != 100 || len(backend.LedgerHistory(accountID)) != 1 {
				t.Fatal("prior credit was applied again")
			}
			for _, identity := range []struct {
				account, reference string
				entryType          contracts.LedgerEntryType
			}{
				{uniqueID("other-account"), reference, contracts.LedgerStripeDeposit},
				{accountID, "stripe:next-checkout", contracts.LedgerStripeDeposit},
				{accountID, reference, contracts.LedgerDeposit},
			} {
				if applied, err := backend.CreditOnce(identity.account, 100, identity.entryType, identity.reference); err != nil || !applied {
					t.Errorf("independent identity %+v: applied=%t error=%v", identity, applied, err)
				}
			}
		})
	}
}

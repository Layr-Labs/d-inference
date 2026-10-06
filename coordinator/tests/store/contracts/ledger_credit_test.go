package store_test

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// ledgerShape is the byte-identical part of a ledger row: what the collapse
// must preserve exactly (ids and created_at are assigned by the database).
type ledgerShape struct {
	Type   store.LedgerEntryType
	Amount int64
	After  int64
	Ref    string
}

// ledgerShapes returns an account's ledger rows oldest-first by id.
func ledgerShapes(s store.Store, accountID string) []ledgerShape {
	entries := s.LedgerHistory(accountID)
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	out := make([]ledgerShape, 0, len(entries))
	for _, e := range entries {
		out = append(out, ledgerShape{Type: e.Type, Amount: e.AmountMicroUSD, After: e.BalanceAfter, Ref: e.Reference})
	}
	return out
}

// TestCreditSemanticsAcrossBackends pins the observable contract on both
// backends: unknown accounts are created, zero and negative amounts are
// applied and recorded, Credit leaves the withdrawable subset alone while
// CreditWithdrawable raises it, and Debit still refuses to overdraw.
func TestCreditSemanticsAcrossBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("sem")
			check := func(step string, wantBal, wantW int64, wantRows []ledgerShape) {
				t.Helper()
				b, w := s.GetBalanceWithWithdrawable(acct)
				if b != wantBal || w != wantW {
					t.Fatalf("%s: balance/withdrawable = (%d,%d), want (%d,%d)", step, b, w, wantBal, wantW)
				}
				if got := ledgerShapes(s, acct); !reflect.DeepEqual(got, wantRows) {
					t.Fatalf("%s: ledger = %+v, want %+v", step, got, wantRows)
				}
			}

			if err := s.Credit(acct, 250, store.LedgerRefund, "a"); err != nil {
				t.Fatalf("credit unknown account: %v", err)
			}
			rows := []ledgerShape{{store.LedgerRefund, 250, 250, "a"}}
			check("unknown account", 250, 0, rows)

			if err := s.Credit(acct, 0, store.LedgerPlatformFee, "z"); err != nil {
				t.Fatalf("zero credit: %v", err)
			}
			rows = append(rows, ledgerShape{store.LedgerPlatformFee, 0, 250, "z"})
			check("zero amount", 250, 0, rows)

			if err := s.Credit(acct, -100, store.LedgerRefund, "n"); err != nil {
				t.Fatalf("negative credit: %v", err)
			}
			rows = append(rows, ledgerShape{store.LedgerRefund, -100, 150, "n"})
			check("negative amount", 150, 0, rows)

			if err := s.CreditWithdrawable(acct, 40, store.LedgerPayout, "w"); err != nil {
				t.Fatalf("credit withdrawable: %v", err)
			}
			rows = append(rows, ledgerShape{store.LedgerPayout, 40, 190, "w"})
			check("withdrawable", 190, 40, rows)

			// A plain Credit on an account whose withdrawable balance is NONZERO
			// must leave it exactly as is (the upsert omits the column).
			if err := s.Credit(acct, 10, store.LedgerRefund, "k"); err != nil {
				t.Fatalf("credit with nonzero withdrawable: %v", err)
			}
			rows = append(rows, ledgerShape{store.LedgerRefund, 10, 200, "k"})
			check("credit keeps nonzero withdrawable", 200, 40, rows)
			for _, e := range s.LedgerHistory(acct) {
				if e.CreatedAt.IsZero() || time.Since(e.CreatedAt) > time.Minute {
					t.Fatalf("ledger row %q created_at=%v, want a fresh database timestamp", e.Reference, e.CreatedAt)
				}
			}

			if err := s.Debit(acct, 1000, store.LedgerCharge, "d"); !errors.Is(err, store.ErrInsufficientBalance) {
				t.Fatalf("overdraw: err=%v, want ErrInsufficientBalance", err)
			}
			check("overdraw refused", 200, 40, rows)
		})
	}
}

// TestConcurrentCreditDebitLedgerConsistency runs 32 goroutines mixing Credit
// and Debit on one account and checks that the final balance equals the seed
// plus every credit minus every successful debit, that the ledger sums to it,
// and that each row's balance_after equals the running sum in id order — the
// chain that a lost update or a mis-read balance_after would break.
func TestConcurrentCreditDebitLedgerConsistency(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("conc")
			const seed = int64(1_000_000)
			if err := s.Credit(acct, seed, store.LedgerRefund, "seed"); err != nil {
				t.Fatalf("seed: %v", err)
			}

			const workers, opsPerWorker = 32, 8
			var wg sync.WaitGroup
			var credited, debited, credits, debits, failures, insufficient atomic.Int64
			for w := 0; w < workers; w++ {
				wg.Add(1)
				go func(w int) {
					defer wg.Done()
					for i := 0; i < opsPerWorker; i++ {
						n := int64((w*opsPerWorker+i)%7+1) * 100
						if (w+i)%2 == 0 {
							if err := s.Credit(acct, n, store.LedgerRefund, fmt.Sprintf("c-%d-%d", w, i)); err != nil {
								failures.Add(1)
								continue
							}
							credited.Add(n)
							credits.Add(1)
							continue
						}
						err := s.Debit(acct, n, store.LedgerCharge, fmt.Sprintf("d-%d-%d", w, i))
						switch {
						case err == nil:
							debited.Add(n)
							debits.Add(1)
						case errors.Is(err, store.ErrInsufficientBalance):
							insufficient.Add(1)
						default:
							failures.Add(1)
						}
					}
				}(w)
			}
			wg.Wait()
			if failures.Load() != 0 {
				t.Fatalf("%d credit/debit calls failed", failures.Load())
			}
			// The seed exceeds every possible debit (max 700 × 128), so a Debit
			// that reports insufficient balance is a broken debit, not a
			// legitimate refusal — the totals below must not be allowed to pass
			// on credits alone.
			if insufficient.Load() != 0 || debits.Load() != workers*opsPerWorker/2 {
				t.Fatalf("debits succeeded=%d insufficient=%d, want %d and 0", debits.Load(), insufficient.Load(), workers*opsPerWorker/2)
			}

			want := seed + credited.Load() - debited.Load()
			if got := s.GetBalance(acct); got != want {
				t.Fatalf("balance = %d, want %d", got, want)
			}
			entries := s.LedgerHistory(acct)
			if int64(len(entries)) != 1+credits.Load()+debits.Load() {
				t.Fatalf("ledger rows = %d, want %d", len(entries), 1+credits.Load()+debits.Load())
			}
			sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
			running := int64(0)
			for _, e := range entries {
				running += e.AmountMicroUSD
				if e.BalanceAfter != running {
					t.Fatalf("ledger id %d: balance_after=%d, running sum=%d (lost update or stale balance_after)", e.ID, e.BalanceAfter, running)
				}
			}
			if running != want {
				t.Fatalf("ledger sum = %d, want %d", running, want)
			}
		})
	}
}

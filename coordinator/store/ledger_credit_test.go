package store

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ledgerShape is the byte-identical part of a ledger row: what the collapse
// must preserve exactly (ids and created_at are assigned by the database).
type ledgerShape struct {
	Type   LedgerEntryType
	Amount int64
	After  int64
	Ref    string
}

// ledgerShapes returns an account's ledger rows oldest-first by id.
func ledgerShapes(s Store, accountID string) []ledgerShape {
	entries := s.LedgerHistory(accountID)
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	out := make([]ledgerShape, 0, len(entries))
	for _, e := range entries {
		out = append(out, ledgerShape{Type: e.Type, Amount: e.AmountMicroUSD, After: e.BalanceAfter, Ref: e.Reference})
	}
	return out
}

// legacyCredit replays the pre-collapse sequence verbatim — BEGIN, balance
// upsert, SELECT balance, ledger INSERT, COMMIT (five round trips) — so the
// single-statement path can be checked against the exact rows it used to
// produce. withdrawable selects the CreditWithdrawable variant of the upsert.
func legacyCredit(t *testing.T, pool *pgxpool.Pool, withdrawable bool, accountID string, amount int64, entryType LedgerEntryType, reference string) {
	t.Helper()
	ctx := context.Background()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("legacy begin: %v", err)
	}
	defer tx.Rollback(ctx)

	upsert := `INSERT INTO balances (account_id, balance_micro_usd, updated_at)
		 VALUES ($1, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   updated_at = NOW()`
	if withdrawable {
		upsert = `INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
		 VALUES ($1, $2, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
		   updated_at = NOW()`
	}
	if _, err := tx.Exec(ctx, upsert, accountID, amount); err != nil {
		t.Fatalf("legacy upsert: %v", err)
	}
	var after int64
	if err := tx.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID).Scan(&after); err != nil {
		t.Fatalf("legacy read balance: %v", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		accountID, string(entryType), amount, after, reference, nullableCreatedAt(time.Time{}),
	); err != nil {
		t.Fatalf("legacy ledger insert: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("legacy commit: %v", err)
	}
}

// TestPostgresCreditIsOneRoundTripAndByteIdentical is the measured effect and
// the equivalence proof in one: the legacy sequence costs five statements per
// credit and the collapsed Credit / CreditWithdrawable cost one, while the
// balances, withdrawable subsets and every ledger row (type, amount,
// balance_after, reference) come out identical — including the unknown
// account (created), the zero amount (recorded) and the negative amount
// (applied) cases.
func TestPostgresCreditIsOneRoundTripAndByteIdentical(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)

	type step struct {
		amount int64
		typ    LedgerEntryType
		ref    string
	}
	steps := []step{
		{100, LedgerRefund, "r1"},     // unknown account: row created
		{50, LedgerPlatformFee, "r2"}, // existing account
		{0, LedgerRefund, "r3"},       // zero: still recorded
		{-30, LedgerRefund, "r4"},     // negative: applied, recorded
	}
	wantRows := []ledgerShape{
		{LedgerRefund, 100, 100, "r1"},
		{LedgerPlatformFee, 50, 150, "r2"},
		{LedgerRefund, 0, 150, "r3"},
		{LedgerRefund, -30, 120, "r4"},
	}

	for _, withdrawable := range []bool{false, true} {
		t.Run(fmt.Sprintf("withdrawable=%v", withdrawable), func(t *testing.T) {
			legacyAcct := uniqueID("legacy")
			cteAcct := uniqueID("cte")

			counter.reset()
			for _, st := range steps {
				legacyCredit(t, s.pool, withdrawable, legacyAcct, st.amount, st.typ, st.ref)
			}
			if q, _, _ := counter.snapshot(); q != 5*len(steps) {
				t.Fatalf("legacy path: %d statements for %d credits, want %d", q, len(steps), 5*len(steps))
			}

			counter.reset()
			for _, st := range steps {
				var err error
				if withdrawable {
					err = s.CreditWithdrawable(cteAcct, st.amount, st.typ, st.ref)
				} else {
					err = s.Credit(cteAcct, st.amount, st.typ, st.ref)
				}
				if err != nil {
					t.Fatalf("credit %+v: %v", st, err)
				}
			}
			if q, b, _ := counter.snapshot(); q != len(steps) || b != 0 {
				t.Fatalf("collapsed path: %d statements / %d batches for %d credits, want %d / 0", q, b, len(steps), len(steps))
			}

			lb, lw := s.GetBalanceWithWithdrawable(legacyAcct)
			cb, cw := s.GetBalanceWithWithdrawable(cteAcct)
			if lb != cb || lw != cw {
				t.Fatalf("balances differ: legacy=(%d,%d) cte=(%d,%d)", lb, lw, cb, cw)
			}
			wantW := int64(0)
			if withdrawable {
				wantW = 120
			}
			if cb != 120 || cw != wantW {
				t.Fatalf("balance/withdrawable = (%d,%d), want (120,%d)", cb, cw, wantW)
			}
			legacyRows, cteRows := ledgerShapes(s, legacyAcct), ledgerShapes(s, cteAcct)
			if !reflect.DeepEqual(legacyRows, wantRows) {
				t.Fatalf("legacy rows = %+v, want %+v", legacyRows, wantRows)
			}
			if !reflect.DeepEqual(cteRows, wantRows) {
				t.Fatalf("collapsed rows = %+v, want %+v (legacy produced %+v)", cteRows, wantRows, legacyRows)
			}
		})
	}
}

// TestPostgresTransactionalCreditCallersUseOneStatement covers the callers
// that keep their own transaction around the credit: the credit inside it is
// now one statement, so CreditProviderWallet is BEGIN + credit + payout row +
// COMMIT and CreditWithdrawableOnce is BEGIN + advisory lock + existence
// check + credit + COMMIT (the duplicate skips the credit).
func TestPostgresTransactionalCreditCallersUseOneStatement(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)

	wallet := uniqueID("wallet")
	fixedAt := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	counter.reset()
	if err := s.CreditProviderWallet(&ProviderPayout{ProviderAddress: wallet, AmountMicroUSD: 700, Model: "m", JobID: uniqueID("job"), Timestamp: fixedAt}); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}
	if q, _, _ := counter.snapshot(); q != 4 {
		t.Fatalf("CreditProviderWallet: %d statements, want 4 (BEGIN, credit, payout, COMMIT)", q)
	}
	// The caller's timestamp must reach the ledger row ($5 binding), not NOW().
	if entries := s.LedgerHistory(wallet); len(entries) != 1 || !entries[0].CreatedAt.Equal(fixedAt) {
		t.Fatalf("wallet ledger created_at = %v, want %v", entries, fixedAt)
	}
	if b, w := s.GetBalanceWithWithdrawable(wallet); b != 700 || w != 700 {
		t.Fatalf("wallet balance/withdrawable = (%d,%d), want (700,700)", b, w)
	}
	if rows := ledgerShapes(s, wallet); len(rows) != 1 || rows[0].Type != LedgerPayout || rows[0].Amount != 700 || rows[0].After != 700 {
		t.Fatalf("wallet ledger = %+v", rows)
	}

	acct, ref := uniqueID("once"), uniqueID("ref")
	counter.reset()
	applied, err := s.CreditWithdrawableOnce(acct, 300, LedgerRefund, ref)
	if err != nil || !applied {
		t.Fatalf("CreditWithdrawableOnce first: applied=%v err=%v", applied, err)
	}
	if q, _, _ := counter.snapshot(); q != 5 {
		t.Fatalf("CreditWithdrawableOnce: %d statements, want 5 (BEGIN, lock, exists, credit, COMMIT)", q)
	}
	counter.reset()
	applied, err = s.CreditWithdrawableOnce(acct, 300, LedgerRefund, ref)
	if err != nil || applied {
		t.Fatalf("CreditWithdrawableOnce duplicate: applied=%v err=%v", applied, err)
	}
	if q, _, _ := counter.snapshot(); q != 4 {
		t.Fatalf("CreditWithdrawableOnce duplicate: %d statements, want 4 (no credit)", q)
	}
	if b, w := s.GetBalanceWithWithdrawable(acct); b != 300 || w != 300 {
		t.Fatalf("once balance/withdrawable = (%d,%d), want (300,300)", b, w)
	}
	if rows := ledgerShapes(s, acct); len(rows) != 1 {
		t.Fatalf("once ledger = %+v, want exactly one row", rows)
	}
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

			if err := s.Credit(acct, 250, LedgerRefund, "a"); err != nil {
				t.Fatalf("credit unknown account: %v", err)
			}
			rows := []ledgerShape{{LedgerRefund, 250, 250, "a"}}
			check("unknown account", 250, 0, rows)

			if err := s.Credit(acct, 0, LedgerPlatformFee, "z"); err != nil {
				t.Fatalf("zero credit: %v", err)
			}
			rows = append(rows, ledgerShape{LedgerPlatformFee, 0, 250, "z"})
			check("zero amount", 250, 0, rows)

			if err := s.Credit(acct, -100, LedgerRefund, "n"); err != nil {
				t.Fatalf("negative credit: %v", err)
			}
			rows = append(rows, ledgerShape{LedgerRefund, -100, 150, "n"})
			check("negative amount", 150, 0, rows)

			if err := s.CreditWithdrawable(acct, 40, LedgerPayout, "w"); err != nil {
				t.Fatalf("credit withdrawable: %v", err)
			}
			rows = append(rows, ledgerShape{LedgerPayout, 40, 190, "w"})
			check("withdrawable", 190, 40, rows)

			// A plain Credit on an account whose withdrawable balance is NONZERO
			// must leave it exactly as is (the upsert omits the column).
			if err := s.Credit(acct, 10, LedgerRefund, "k"); err != nil {
				t.Fatalf("credit with nonzero withdrawable: %v", err)
			}
			rows = append(rows, ledgerShape{LedgerRefund, 10, 200, "k"})
			check("credit keeps nonzero withdrawable", 200, 40, rows)
			for _, e := range s.LedgerHistory(acct) {
				if e.CreatedAt.IsZero() || time.Since(e.CreatedAt) > time.Minute {
					t.Fatalf("ledger row %q created_at=%v, want a fresh database timestamp", e.Reference, e.CreatedAt)
				}
			}

			if err := s.Debit(acct, 1000, LedgerCharge, "d"); !errors.Is(err, ErrInsufficientBalance) {
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
			if err := s.Credit(acct, seed, LedgerRefund, "seed"); err != nil {
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
							if err := s.Credit(acct, n, LedgerRefund, fmt.Sprintf("c-%d-%d", w, i)); err != nil {
								failures.Add(1)
								continue
							}
							credited.Add(n)
							credits.Add(1)
							continue
						}
						err := s.Debit(acct, n, LedgerCharge, fmt.Sprintf("d-%d-%d", w, i))
						switch {
						case err == nil:
							debited.Add(n)
							debits.Add(1)
						case errors.Is(err, ErrInsufficientBalance):
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

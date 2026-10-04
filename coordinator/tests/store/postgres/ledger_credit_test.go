package postgres_test

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgxpool"
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

// legacyCredit replays the pre-collapse sequence verbatim — BEGIN, balance
// upsert, SELECT balance, ledger INSERT, COMMIT (five round trips) — so the
// single-statement path can be checked against the exact rows it used to
// produce. withdrawable selects the CreditWithdrawable variant of the upsert.
func legacyCredit(t *testing.T, pool *pgxpool.Pool, withdrawable bool, accountID string, amount int64, entryType store.LedgerEntryType, reference string) {
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
		accountID, string(entryType), amount, after, reference, nil,
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
		typ    store.LedgerEntryType
		ref    string
	}
	steps := []step{
		{100, store.LedgerRefund, "r1"},     // unknown account: row created
		{50, store.LedgerPlatformFee, "r2"}, // existing account
		{0, store.LedgerRefund, "r3"},       // zero: still recorded
		{-30, store.LedgerRefund, "r4"},     // negative: applied, recorded
	}
	wantRows := []ledgerShape{
		{store.LedgerRefund, 100, 100, "r1"},
		{store.LedgerPlatformFee, 50, 150, "r2"},
		{store.LedgerRefund, 0, 150, "r3"},
		{store.LedgerRefund, -30, 120, "r4"},
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

// TestPostgresTransactionalCreditCallersUseOneStatement covers the caller
// that keeps its own transaction around the credit: the credit inside it is
// one statement, so CreditWithdrawableOnce is BEGIN + advisory lock +
// existence check + credit + COMMIT (the duplicate skips the credit).
func TestPostgresTransactionalCreditCallersUseOneStatement(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)

	acct, ref := uniqueID("once"), uniqueID("ref")
	counter.reset()
	applied, err := s.CreditWithdrawableOnce(acct, 300, store.LedgerRefund, ref)
	if err != nil || !applied {
		t.Fatalf("CreditWithdrawableOnce first: applied=%v err=%v", applied, err)
	}
	if q, _, _ := counter.snapshot(); q != 5 {
		t.Fatalf("CreditWithdrawableOnce: %d statements, want 5 (BEGIN, lock, exists, credit, COMMIT)", q)
	}
	counter.reset()
	applied, err = s.CreditWithdrawableOnce(acct, 300, store.LedgerRefund, ref)
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

package assert

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

type AccountingAsserter struct {
	store store.Store
}

func NewAccountingAsserter(st store.Store) *AccountingAsserter {
	return &AccountingAsserter{store: st}
}

func (a *AccountingAsserter) EvaluateAll(ctx context.Context) *AssertionReport {
	report := &AssertionReport{
		Timestamp: time.Now(),
		Passed:    true,
	}

	a.assertBalanceIntegrity(report)
	a.assertNoNegativeBalances(report)

	return report
}

func (a *AccountingAsserter) assertBalanceIntegrity(report *AssertionReport) {
	name := "balance_integrity"

	usage := a.store.UsageRecords()
	if len(usage) == 0 {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  true,
			Message: "no usage records to verify",
		})
		return
	}

	accounts := make(map[string]bool)
	for _, u := range usage {
		accounts[u.ConsumerKey] = true
	}

	driftCount := 0
	for acc := range accounts {
		balance := a.store.GetBalance(acc)
		if balance < 0 {
			driftCount++
		}
	}

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  driftCount == 0,
		Message: fmt.Sprintf("%d accounts with balance drift (store interface cannot verify sum-of-ledger — use PostgresAccountingAsserter)", driftCount),
	})
	if driftCount > 0 {
		report.Passed = false
	}
}

func (a *AccountingAsserter) assertNoNegativeBalances(report *AssertionReport) {
	name := "no_negative_balances"

	usage := a.store.UsageRecords()
	for _, u := range usage {
		consumerKey := u.ConsumerKey
		balance := a.store.GetBalance(consumerKey)
		if balance < 0 {
			report.Results = append(report.Results, AssertionResult{
				Name:    name,
				Passed:  false,
				Message: fmt.Sprintf("account %s has negative balance: %d micro-USD", consumerKey, balance),
			})
			report.Passed = false
			return
		}
	}

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  true,
		Message: "no negative balances detected",
	})
}

type PostgresAccountingAsserter struct {
	pool *pgxpool.Pool
}

func NewPostgresAccountingAsserter(pool *pgxpool.Pool) *PostgresAccountingAsserter {
	return &PostgresAccountingAsserter{pool: pool}
}

func (pa *PostgresAccountingAsserter) EvaluateAll(ctx context.Context) *AssertionReport {
	report := &AssertionReport{
		Timestamp: time.Now(),
		Passed:    true,
	}

	if pa.pool == nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    "postgres_connection",
			Passed:  false,
			Message: "no pgxpool.Pool connection provided",
		})
		report.Passed = false
		return report
	}

	pa.assertBalanceIntegritySQL(ctx, report)
	pa.assertNoNegativeBalancesSQL(ctx, report)
	pa.assertLedgerContinuitySQL(ctx, report)
	pa.assertPaymentEarningsParitySQL(ctx, report)
	pa.assertEarningsMatchesPaymentsSQL(ctx, report)
	pa.assertBillingSessionConsistencySQL(ctx, report)

	return report
}

func (pa *PostgresAccountingAsserter) assertBalanceIntegritySQL(ctx context.Context, report *AssertionReport) {
	name := "balance_integrity_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM balances b
		WHERE b.balance_micro_usd != COALESCE((
			SELECT SUM(amount_micro_usd) FROM ledger_entries
			WHERE account_id = b.account_id
		), 0)
	`)

	var driftCount int
	if err := row.Scan(&driftCount); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	passed := driftCount == 0
	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  passed,
		Message: fmt.Sprintf("%d accounts with balance drift", driftCount),
	})
	if !passed {
		report.Passed = false
	}
}

func (pa *PostgresAccountingAsserter) assertNoNegativeBalancesSQL(ctx context.Context, report *AssertionReport) {
	name := "no_negative_balances_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM balances WHERE balance_micro_usd < 0
	`)

	var negCount int
	if err := row.Scan(&negCount); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	passed := negCount == 0
	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  passed,
		Message: fmt.Sprintf("%d accounts with negative balance", negCount),
	})
	if !passed {
		report.Passed = false
	}
}

func (pa *PostgresAccountingAsserter) assertLedgerContinuitySQL(ctx context.Context, report *AssertionReport) {
	name := "ledger_continuity_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM (
			SELECT le.id,
			       le.account_id,
			       le.amount_micro_usd,
			       le.balance_after,
			       LAG(le.balance_after) OVER (PARTITION BY le.account_id ORDER BY le.id) AS prev_balance_after
			FROM ledger_entries le
		) sub
		WHERE prev_balance_after IS NOT NULL
		  AND prev_balance_after + amount_micro_usd != balance_after
	`)

	var gapCount int
	if err := row.Scan(&gapCount); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	passed := gapCount == 0
	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  passed,
		Message: fmt.Sprintf("%d ledger continuity gaps found", gapCount),
	})
	if !passed {
		report.Passed = false
	}
}

func (pa *PostgresAccountingAsserter) assertPaymentEarningsParitySQL(ctx context.Context, report *AssertionReport) {
	name := "payment_earnings_parity_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM (
			SELECT le.account_id
			FROM ledger_entries le
			WHERE le.entry_type = 'platform_fee'
			GROUP BY le.account_id
		) sub
	`)

	var feeAccountCount int
	if err := row.Scan(&feeAccountCount); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  true,
		Message: fmt.Sprintf("%d accounts with platform fee entries recorded", feeAccountCount),
	})
}

func (pa *PostgresAccountingAsserter) assertEarningsMatchesPaymentsSQL(ctx context.Context, report *AssertionReport) {
	name := "earnings_matches_payments_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(le.amount_micro_usd), 0)
		FROM ledger_entries le
		WHERE le.entry_type IN ('charge', 'refund')
	`)

	var totalCharges int
	if err := row.Scan(&totalCharges); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  true,
		Message: fmt.Sprintf("net charges across all accounts: %d micro-USD", totalCharges),
	})
}

func (pa *PostgresAccountingAsserter) assertBillingSessionConsistencySQL(ctx context.Context, report *AssertionReport) {
	name := "billing_session_consistency_sql"

	row := pa.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM billing_sessions
		WHERE completed_at IS NOT NULL AND status != 'completed'
	`)

	var inconsistent int
	if err := row.Scan(&inconsistent); err != nil {
		report.Results = append(report.Results, AssertionResult{
			Name:    name,
			Passed:  false,
			Message: fmt.Sprintf("query failed: %v", err),
		})
		report.Passed = false
		return
	}

	passed := inconsistent == 0
	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  passed,
		Message: fmt.Sprintf("%d billing sessions with completed_at set but status != 'completed'", inconsistent),
	})
	if !passed {
		report.Passed = false
	}
}

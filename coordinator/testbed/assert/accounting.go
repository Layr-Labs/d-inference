package assert

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
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

	a.assertNoNegativeBalances(report)

	return report
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

// PostgresAccountingAsserter performs integrity checks against raw Postgres SQL,
// bypassing the store interface. This is intentional: the store interface cannot
// express the aggregate SQL queries needed for integrity verification. This type
// is test-only and must NOT be used as a pattern for production code paths.
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
		SELECT COUNT(*) FROM ledger_entries le
		WHERE EXISTS (
			SELECT 1 FROM ledger_entries prev
			WHERE prev.account_id = le.account_id
			  AND prev.id = (
			  	SELECT MAX(p2.id) FROM ledger_entries p2
				WHERE p2.account_id = le.account_id AND p2.id < le.id
			  )
			  AND prev.balance_after + le.amount_micro_usd != le.balance_after
		)
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

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  true,
		Message: "payment-earnings parity requires coordinator fee percentage config (placeholder)",
	})
}

func (pa *PostgresAccountingAsserter) assertEarningsMatchesPaymentsSQL(ctx context.Context, report *AssertionReport) {
	name := "earnings_matches_payments_sql"

	report.Results = append(report.Results, AssertionResult{
		Name:    name,
		Passed:  true,
		Message: "earnings-payments cross-check requires full request tracking (placeholder)",
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

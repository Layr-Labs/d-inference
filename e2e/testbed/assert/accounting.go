package assert

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
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

	for _, check := range accountingSQLChecks() {
		check.evaluate(report, pa.pool.QueryRow(ctx, check.query))
	}

	return report
}

// observation preserves the two existing informational accounting results: their
// counts are reported, but they do not establish payment/earnings equality.
type accountingSQLCheck struct {
	name, query, message string
	observation          bool
}

func accountingSQLChecks() []accountingSQLCheck {
	return []accountingSQLCheck{
		{
			name: "balance_integrity_sql",
			query: `
		SELECT COUNT(*) FROM balances b
		WHERE b.balance_micro_usd != COALESCE((
			SELECT SUM(amount_micro_usd) FROM ledger_entries
			WHERE account_id = b.account_id
		), 0)
	`,
			message: "%d accounts with balance drift",
		},
		{
			name: "no_negative_balances_sql",
			query: `
		SELECT COUNT(*) FROM balances WHERE balance_micro_usd < 0
	`,
			message: "%d accounts with negative balance",
		},
		{
			name: "ledger_continuity_sql",
			query: `
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
	`,
			message: "%d ledger continuity gaps found",
		},
		{
			name: "payment_earnings_parity_sql",
			query: `
		SELECT COUNT(*) FROM (
			SELECT le.account_id
			FROM ledger_entries le
			WHERE le.entry_type = 'platform_fee'
			GROUP BY le.account_id
		) sub
	`,
			message:     "%d accounts with platform fee entries recorded",
			observation: true,
		},
		{
			name: "earnings_matches_payments_sql",
			query: `
		SELECT COALESCE(SUM(le.amount_micro_usd), 0)
		FROM ledger_entries le
		WHERE le.entry_type IN ('charge', 'refund')
	`,
			message:     "net charges across all accounts: %d micro-USD",
			observation: true,
		},
		{
			name: "billing_session_consistency_sql",
			query: `
		SELECT COUNT(*) FROM billing_sessions
		WHERE completed_at IS NOT NULL AND status != 'completed'
	`,
			message: "%d billing sessions with completed_at set but status != 'completed'",
		},
	}
}

func (check accountingSQLCheck) evaluate(report *AssertionReport, row pgx.Row) {
	var count int
	result := AssertionResult{Name: check.name}
	if err := row.Scan(&count); err != nil {
		result.Message = fmt.Sprintf("query failed: %v", err)
	} else {
		result.Passed = check.observation || count == 0
		result.Message = fmt.Sprintf(check.message, count)
	}
	report.Results = append(report.Results, result)
	if !result.Passed {
		report.Passed = false
	}
}

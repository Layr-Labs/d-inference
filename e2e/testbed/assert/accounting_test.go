package assert

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
)

type accountingRow struct {
	count int
	err   error
}

func (row accountingRow) Scan(dest ...any) error {
	if row.err != nil {
		return row.err
	}
	if len(dest) != 1 {
		return fmt.Errorf("expected one destination, got %d", len(dest))
	}
	count, ok := dest[0].(*int)
	if !ok {
		return fmt.Errorf("expected *int destination, got %T", dest[0])
	}
	*count = row.count
	return nil
}

func TestAccountingSQLResultContracts(t *testing.T) {
	// These report names and ordering are consumed by existing E2E reports.
	checks := accountingSQLChecks()
	require.Len(t, checks, 6)
	wantNames := []string{
		"balance_integrity_sql", "no_negative_balances_sql", "ledger_continuity_sql",
		"payment_earnings_parity_sql", "earnings_matches_payments_sql", "billing_session_consistency_sql",
	}
	wantMessages := []string{
		"%d accounts with balance drift", "%d accounts with negative balance", "%d ledger continuity gaps found",
		"%d accounts with platform fee entries recorded", "net charges across all accounts: %d micro-USD",
		"%d billing sessions with completed_at set but status != 'completed'",
	}
	for i, check := range checks {
		t.Run(wantNames[i], func(t *testing.T) {
			require.Equal(t, wantNames[i], check.name)
			for _, count := range []int{0, 2, -3} {
				report := &AssertionReport{Passed: true}
				check.evaluate(report, accountingRow{count: count})
				// The fee-count and net-charge observations are intentionally
				// informational, including nonzero and negative net charges.
				passed := count == 0 || i == 3 || i == 4
				require.Equal(t, passed, report.Passed)
				require.Equal(t, []AssertionResult{{Name: wantNames[i], Passed: passed, Message: fmt.Sprintf(wantMessages[i], count)}}, report.Results)
			}
			report := &AssertionReport{Passed: true}
			check.evaluate(report, accountingRow{err: errors.New("scan failed")})
			require.False(t, report.Passed)
			require.Equal(t, []AssertionResult{{Name: wantNames[i], Message: "query failed: scan failed"}}, report.Results)
			check.evaluate(report, accountingRow{})
			require.False(t, report.Passed, "later passing results cannot clear an earlier failure")
			require.Len(t, report.Results, 2)
		})
	}
}

func TestPostgresAccountingRequiresConnection(t *testing.T) {
	report := NewPostgresAccountingAsserter(nil).EvaluateAll(context.Background())
	require.False(t, report.Passed)
	require.False(t, report.Timestamp.IsZero())
	require.Equal(t, []AssertionResult{{Name: "postgres_connection", Message: "no pgxpool.Pool connection provided"}}, report.Results)
}

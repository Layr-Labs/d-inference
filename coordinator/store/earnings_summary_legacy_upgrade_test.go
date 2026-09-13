package store

import (
	"context"
	"os"
	"testing"
)

// Chronology matters: earnings_summary and its ON CONFLICT DO NOTHING boot
// backfill shipped in de67e28f5 (2026-05-27). Base rewards shipped later in
// 053f8c220 (2026-06-20), already inserting both summaries atomically with zero
// inference counts/tokens. Current production callers remain:
// payments/baserewards/engine.go -> SettleProviderFloorDraw, and inference
// completion in api/provider.go -> CreditProviderAccount. RecordProviderEarning
// has no production caller. These exact old statements make the normal upgrade
// evidence independent of the new writer filtering added by this PR.
func legacyFloorUpgradeStore(t *testing.T) *PostgresStore {
	t.Helper()
	s, err := NewPostgres(context.Background(), Config{DatabaseURL: newWithdrawableTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	// Bootstrap only schema, then remove the empty-database new migration markers
	// so the test can replay the old serving/boot behavior before the new upgrade.
	_, err = s.pool.Exec(context.Background(), `DELETE FROM schema_migrations WHERE id=ANY($1::text[])`,
		[]string{earningsSummaryMigrationID, earningsSummaryPlanID, earningsSummaryPlanAttemptID})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func executeLegacyFloorSettlement(t *testing.T, s *PostgresStore) {
	t.Helper()
	sql, err := os.ReadFile("testdata/settle_provider_floor_draw_053f8c220.sql")
	if err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		var credited bool
		err := s.pool.QueryRow(context.Background(), string(sql), "p", "a", "floor-epoch", int64(800), int64(800), int64(0), float64(1), float64(64), string(LedgerFloorDraw), "floor:floor-epoch:p").Scan(&credited)
		if err != nil || credited != (attempt == 0) {
			t.Fatalf("legacy floor attempt%d: credited=%v err=%v", attempt, credited, err)
		}
	}
}

func executeLegacyBootBackfill(t *testing.T, s *PostgresStore) {
	t.Helper()
	sql, err := os.ReadFile("testdata/earnings_summary_boot_884d97862.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(context.Background(), string(sql)); err != nil {
		t.Fatal(err)
	}
}

func assertLegacyUpgradeSummaries(t *testing.T, s *PostgresStore, want ProviderEarningsSummary) {
	t.Helper()
	account, err := s.GetAccountEarningsSummary("a")
	if err != nil {
		t.Fatal(err)
	}
	provider, err := s.GetProviderEarningsSummary("p")
	if err != nil {
		t.Fatal(err)
	}
	if account != want || provider != want {
		t.Fatalf("account=%+v provider=%+v want=%+v", account, provider, want)
	}
}

func TestLegacyFloorSettlementBootAndUpgradeKeepBaseRewardsOutOfWork(t *testing.T) {
	for _, withInference := range []bool{false, true} {
		name := "floor_only"
		if withInference {
			name = "floor_and_inference"
		}
		t.Run(name, func(t *testing.T) {
			s := legacyFloorUpgradeStore(t)
			executeLegacyFloorSettlement(t, s)
			want := ProviderEarningsSummary{TotalMicroUSD: 800}
			if withInference {
				tx, err := s.pool.Begin(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				defer tx.Rollback(context.Background())
				executeOldServingCredit(t, tx)
				if err := tx.Commit(context.Background()); err != nil {
					t.Fatal(err)
				}
				want = ProviderEarningsSummary{Count: 1, TotalMicroUSD: 850, PromptTokens: 5, CompletionTokens: 7}
			}
			assertLegacyUpgradeSummaries(t, s, want)
			// The old COUNT(*) could count the base row, but the key already exists
			// from the atomic floor transaction, so DO NOTHING must preserve its zero.
			executeLegacyBootBackfill(t, s)
			assertLegacyUpgradeSummaries(t, s, want)
			if _, err := s.applyEarningsSummaryMigration(context.Background()); err != nil {
				t.Fatal(err)
			}
			assertLegacyUpgradeSummaries(t, s, want)
		})
	}
}

func TestLegacyFloorUpgradePreservesLifetimeWorkDespiteRetainedHistory(t *testing.T) {
	s := legacyFloorUpgradeStore(t)
	executeLegacyFloorSettlement(t, s)
	sql, err := os.ReadFile("testdata/credit_provider_account_884d97862.sql")
	if err != nil {
		t.Fatal(err)
	}
	// An ordinary paid inference later disappears from retained history while
	// the correctly maintained lifetime summary deliberately remains.
	for _, job := range []struct {
		id                 string
		amount             int64
		prompt, completion int
	}{
		{"retained", 50, 5, 7}, {"pruned-paid-work", 80, 3, 4},
	} {
		var balance int64
		err := s.pool.QueryRow(context.Background(), string(sql), "a", job.amount, string(LedgerPayout), job.id, nil, "live", "p", "m", job.prompt, job.completion).Scan(&balance)
		if err != nil {
			t.Fatal(err)
		}
	}
	want := ProviderEarningsSummary{Count: 2, TotalMicroUSD: 930, PromptTokens: 8, CompletionTokens: 11}
	assertLegacyUpgradeSummaries(t, s, want)
	if _, err := s.pool.Exec(context.Background(), `DELETE FROM provider_earnings WHERE job_id='pruned-paid-work'`); err != nil {
		t.Fatal(err)
	}
	// The retained total row count (including the base reward) happens to match
	// the lifetime inference count. Subtracting that base reward or recomputing
	// work/tokens from retained rows would erase an actual paid historical job.
	var retained ProviderEarningsSummary
	err = s.pool.QueryRow(context.Background(), `SELECT COUNT(*),SUM(amount_micro_usd),SUM(prompt_tokens),SUM(completion_tokens) FROM provider_earnings WHERE account_id='a'`).Scan(&retained.Count, &retained.TotalMicroUSD, &retained.PromptTokens, &retained.CompletionTokens)
	if err != nil || retained.Count != want.Count || retained.TotalMicroUSD != 850 || retained.PromptTokens != 5 || retained.CompletionTokens != 7 {
		t.Fatalf("ambiguous retained fixture: %+v %v", retained, err)
	}
	executeLegacyBootBackfill(t, s)
	if _, err := s.applyEarningsSummaryMigration(context.Background()); err != nil {
		t.Fatal(err)
	}
	assertLegacyUpgradeSummaries(t, s, want)
}

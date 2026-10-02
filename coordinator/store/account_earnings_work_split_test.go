package store

import (
	"context"
	"testing"
)

func settleDrawFor(t *testing.T, s Store, acct, pk, epoch string, amount int64) bool {
	t.Helper()
	return settleFloorDraw(t, s, &ProviderFloorDraw{
		ProviderKey: pk, AccountID: acct, EpochID: epoch,
		AmountMicroUSD: amount, FloorMicroUSD: amount, UptimeFrac: 1, MemoryGB: 64,
	})
}

// W1: base reward = sum of settled draws; total and count keep their meaning.
func TestW1AccountSummaryBaseRewardEqualsSettledDraws(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w1")
			pk := uniqueID("pk-w1")
			for i, amt := range []int64{300, 700} {
				if err := s.RecordProviderEarning(&ProviderEarning{
					AccountID: acct, ProviderID: "p", ProviderKey: pk,
					JobID: uniqueID("job"), Model: "model", AmountMicroUSD: amt,
					PromptTokens: 1, CompletionTokens: 2,
				}); err != nil {
					t.Fatalf("record %d: %v", i, err)
				}
			}
			if !settleDrawFor(t, s, acct, pk, "2026-01", 5_000) || !settleDrawFor(t, s, acct, pk, "2026-02", 7_000) {
				t.Fatal("draw not settled")
			}
			got, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if got.BaseRewardMicroUSD != 12_000 {
				t.Fatalf("BaseRewardMicroUSD = %d, want 12000", got.BaseRewardMicroUSD)
			}
			if got.TotalMicroUSD != 1_000+12_000 || got.Count != 2 {
				t.Fatalf("total=%d count=%d, want 13000 and 2", got.TotalMicroUSD, got.Count)
			}
		})
	}
}

// W2: CreditProviderAccount grows the column only for model base_reward.
func TestW2CreditProviderAccountBaseRewardOnly(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w2")
			pk := uniqueID("pk-w2")
			if err := s.CreditProviderAccount(&ProviderEarning{
				AccountID: acct, ProviderID: "p", ProviderKey: pk, JobID: uniqueID("job"),
				Model: "qwen3.5-9b", AmountMicroUSD: 400,
			}); err != nil {
				t.Fatal(err)
			}
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 0 || sum.TotalMicroUSD != 400 {
				t.Fatalf("after inference credit: %+v, want base 0 total 400", sum)
			}
			if err := s.CreditProviderAccount(&ProviderEarning{
				AccountID: acct, ProviderID: "p", ProviderKey: pk, JobID: uniqueID("job"),
				Model: "base_reward", AmountMicroUSD: 900,
			}); err != nil {
				t.Fatal(err)
			}
			sum, err = s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 900 || sum.TotalMicroUSD != 1_300 {
				t.Fatalf("after base_reward credit: %+v, want base 900 total 1300", sum)
			}
		})
	}
}

// W3: a duplicate draw and a zero-amount draw leave the column unchanged.
func TestW3DuplicateAndZeroDrawLeaveBaseRewardUnchanged(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w3")
			pk := uniqueID("pk-w3")
			if !settleDrawFor(t, s, acct, pk, "2026-03", 2_500) {
				t.Fatal("first draw not settled")
			}
			if settleDrawFor(t, s, acct, pk, "2026-03", 2_500) {
				t.Fatal("duplicate draw reported settled")
			}
			settleDrawFor(t, s, acct, pk, "2026-04", 0)
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 2_500 || sum.TotalMicroUSD != 2_500 {
				t.Fatalf("summary %+v, want base 2500 total 2500", sum)
			}
		})
	}
}

const (
	w4DoneMarker = "backfill_earnings_summary_base_reward_v1"
	w4PlanMarker = "prepare_earnings_summary_base_reward_v1"
)

func baseRewardColumn(t *testing.T, s *PostgresStore, key, keyType string) int64 {
	t.Helper()
	var v int64
	if err := s.pool.QueryRow(context.Background(),
		`SELECT total_base_reward_micro_usd FROM earnings_summary WHERE key=$1 AND key_type=$2`,
		key, keyType).Scan(&v); err != nil {
		t.Fatalf("read column %s/%s: %v", keyType, key, err)
	}
	return v
}

func markerCount(t *testing.T, s *PostgresStore, id string) int {
	t.Helper()
	var n int
	if err := s.pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM schema_migrations WHERE id=$1`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func pendingCount(t *testing.T, s *PostgresStore) int {
	t.Helper()
	var n int
	if err := s.pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM earnings_summary_base_reward_pending`).Scan(&n); err != nil {
		t.Fatalf("pending table: %v", err)
	}
	return n
}

// W4: backfill from draws; idempotent; provider rows untouched.
func TestW4BaseRewardBackfillFromDraws(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	a1, a2 := uniqueID("acct-w4a"), uniqueID("acct-w4b")
	pk1, pk2 := uniqueID("pk-w4a"), uniqueID("pk-w4b")
	settleDrawFor(t, s, a1, pk1, "2026-01", 1_000)
	settleDrawFor(t, s, a1, pk1, "2026-02", 2_000)
	settleDrawFor(t, s, a2, pk2, "2026-01", 5_000)
	settleDrawFor(t, s, a2, pk2, "2026-02", 0) // zero draws do not count

	// Pre-migration state: column zeroed, markers gone, provider row present.
	if _, err := s.pool.Exec(ctx, `UPDATE earnings_summary SET total_base_reward_micro_usd = 0`); err != nil {
		t.Fatalf("zero column: %v", err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, total_base_reward_micro_usd, updated_at)
		VALUES ($1, 'provider', 0, 123, 0, 0, 777, NOW())`, pk1); err != nil {
		t.Fatalf("insert provider row: %v", err)
	}
	if _, err := s.pool.Exec(ctx, `DELETE FROM schema_migrations WHERE id IN ($1, $2)`, w4DoneMarker, w4PlanMarker); err != nil {
		t.Fatal(err)
	}

	if err := s.migrateEarningsSummaryBaseReward(ctx); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	check := func(label string) {
		if got := baseRewardColumn(t, s, a1, "account"); got != 3_000 {
			t.Fatalf("%s: a1 = %d, want 3000", label, got)
		}
		if got := baseRewardColumn(t, s, a2, "account"); got != 5_000 {
			t.Fatalf("%s: a2 = %d, want 5000", label, got)
		}
		if got := baseRewardColumn(t, s, pk1, "provider"); got != 777 {
			t.Fatalf("%s: provider row = %d, want 777 untouched", label, got)
		}
		if markerCount(t, s, w4DoneMarker) != 1 {
			t.Fatalf("%s: done marker missing", label)
		}
		if n := pendingCount(t, s); n != 0 {
			t.Fatalf("%s: pending rows = %d, want 0", label, n)
		}
	}
	check("after first run")
	if err := s.migrateEarningsSummaryBaseReward(ctx); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	check("after second run")
}

// W4 crash resume: plan marker present with a pending row; one call applies it
// once. The pending table shape (account_id, amount_micro_usd) is part of the
// seam; the test creates it with that shape when the code has not yet.
func TestW4BaseRewardBackfillResumesPendingOnce(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	acct := uniqueID("acct-w4c")
	settleDrawFor(t, s, acct, uniqueID("pk-w4c"), "2026-01", 4_000)
	if _, err := s.pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS earnings_summary_base_reward_pending (
		account_id TEXT PRIMARY KEY, amount_micro_usd BIGINT NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `TRUNCATE earnings_summary_base_reward_pending`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `UPDATE earnings_summary SET total_base_reward_micro_usd = 0`); err != nil {
		t.Fatalf("zero column: %v", err)
	}
	if _, err := s.pool.Exec(ctx, `DELETE FROM schema_migrations WHERE id IN ($1, $2)`, w4DoneMarker, w4PlanMarker); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO earnings_summary_base_reward_pending (account_id, amount_micro_usd) VALUES ($1, 4000)`, acct); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO schema_migrations (id) VALUES ($1)`, w4PlanMarker); err != nil {
		t.Fatal(err)
	}

	if err := s.migrateEarningsSummaryBaseReward(ctx); err != nil {
		t.Fatalf("resume migrate: %v", err)
	}
	if got := baseRewardColumn(t, s, acct, "account"); got != 4_000 {
		t.Fatalf("column = %d, want 4000 applied once", got)
	}
	if n := pendingCount(t, s); n != 0 {
		t.Fatalf("pending rows = %d, want 0", n)
	}
	if markerCount(t, s, w4DoneMarker) != 1 {
		t.Fatal("done marker missing")
	}
}

// W5: with the done marker present the column is not rewritten.
func TestW5BaseRewardBackfillSkippedWhenMarkerPresent(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	acct := uniqueID("acct-w5")
	settleDrawFor(t, s, acct, uniqueID("pk-w5"), "2026-01", 9_000)
	if _, err := s.pool.Exec(ctx, `UPDATE earnings_summary SET total_base_reward_micro_usd = 1 WHERE key=$1 AND key_type='account'`, acct); err != nil {
		t.Fatalf("set sentinel: %v", err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO schema_migrations (id) VALUES ($1) ON CONFLICT DO NOTHING`, w4DoneMarker); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateEarningsSummaryBaseReward(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if got := baseRewardColumn(t, s, acct, "account"); got != 1 {
		t.Fatalf("column = %d, want sentinel 1 (marker present, no rewrite)", got)
	}
}

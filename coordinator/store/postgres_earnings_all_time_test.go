package store

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"
)

// seedAllTimeEarnings gives a backend the mix the all-time paths must agree
// on: inference work, base rewards settled as a floor draw and recorded as a
// plain base_reward earning, ledger rewards for a provider and for a
// consumer-only account, and an earning with no account attached.
//
//	alice  work 1250 (2 jobs, 165 tokens)
//	carol  work 500  (1 job, 15 tokens) + floor draw 300 + admin_reward 700
//	dave   base_reward earning 900 only
//	bob    referral_reward 2000 only -> not a provider
//	""     work 40 (1 job, 8 tokens) under provider key pk-orphan
func seedAllTimeEarnings(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	now := time.Now()
	credit := func(acct, pk string, micro int64, pt, ct int) {
		if err := s.CreditProviderAccount(&ProviderEarning{
			AccountID: acct, ProviderID: "p", ProviderKey: pk, JobID: uniqueID("job"), Model: "m",
			AmountMicroUSD: micro, PromptTokens: pt, CompletionTokens: ct, CreatedAt: now,
		}); err != nil {
			t.Fatalf("credit %s: %v", acct, err)
		}
	}
	credit("acct-alice", "pk-alice", 1000, 100, 50)
	credit("acct-alice", "pk-alice", 250, 10, 5)
	credit("acct-carol", "pk-carol", 500, 10, 5)
	if _, err := s.SettleProviderFloorDraw(ctx, &ProviderFloorDraw{
		ProviderKey: "pk-carol", AccountID: "acct-carol", EpochID: uniqueID("epoch"), AmountMicroUSD: 300,
	}); err != nil {
		t.Fatalf("settle floor draw: %v", err)
	}
	if err := s.CreditWithdrawable("acct-carol", 700, LedgerAdminReward, uniqueID("ref")); err != nil {
		t.Fatalf("credit carol reward: %v", err)
	}
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-dave", ProviderKey: "pk-dave", JobID: uniqueID("job"), Model: "base_reward",
		AmountMicroUSD: 900, CreatedAt: now,
	}); err != nil {
		t.Fatalf("record dave base reward: %v", err)
	}
	if err := s.CreditWithdrawable("acct-bob", 2000, LedgerReferralReward, uniqueID("ref")); err != nil {
		t.Fatalf("credit bob reward: %v", err)
	}
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: "", ProviderKey: "pk-orphan", JobID: uniqueID("job"), Model: "m",
		AmountMicroUSD: 40, PromptTokens: 4, CompletionTokens: 4, CreatedAt: now,
	}); err != nil {
		t.Fatalf("record orphan earning: %v", err)
	}
}

// TestAllTimeTotalsAndLeaderboardAgreeAcrossBackends pins the all-time numbers
// on both backends. On Postgres they come from earnings_summary, so this also
// checks that every write path maintains total_base_reward_micro_usd.
func TestAllTimeTotalsAndLeaderboardAgreeAcrossBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			seedAllTimeEarnings(t, s)

			totals, err := s.NetworkTotals(time.Time{})
			if err != nil {
				t.Fatalf("network totals: %v", err)
			}
			want := NetworkTotalsRow{
				EarningsMicroUSD: 1790 + 1200 + 700, WorkEarningsMicroUSD: 1790, RewardEarningsMicroUSD: 1200 + 700,
				Tokens: 188, Jobs: 4, ActiveAccounts: 3,
			}
			if totals != want {
				t.Fatalf("network totals = %+v, want %+v", totals, want)
			}

			rows := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50)
			wantRows := []LeaderboardRow{
				{AccountID: "acct-carol", EarningsMicroUSD: 1500, WorkEarningsMicroUSD: 500, RewardEarningsMicroUSD: 1000, Tokens: 15, Jobs: 1},
				{AccountID: "acct-alice", EarningsMicroUSD: 1250, WorkEarningsMicroUSD: 1250, Tokens: 165, Jobs: 2},
				{AccountID: "acct-dave", EarningsMicroUSD: 900, RewardEarningsMicroUSD: 900},
			}
			if !reflect.DeepEqual(rows, wantRows) {
				t.Fatalf("leaderboard = %+v, want %+v", rows, wantRows)
			}
			if got := rowIDs(s.Leaderboard(LeaderboardTokens, time.Time{}, 50)); !reflect.DeepEqual(got, []string{"acct-alice", "acct-carol", "acct-dave"}) {
				t.Fatalf("tokens order = %v", got)
			}
			if got := rowIDs(s.Leaderboard(LeaderboardJobs, time.Time{}, 2)); !reflect.DeepEqual(got, []string{"acct-alice", "acct-carol"}) {
				t.Fatalf("jobs order (limit 2) = %v", got)
			}
		})
	}
}

func rowIDs(rows []LeaderboardRow) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.AccountID)
	}
	return out
}

// TestPostgresAllTimeMatchesWindowScan: the summary-backed all-time path
// returns exactly what the provider_earnings scan returns for a window that
// starts at the Unix epoch, and it really is the summary that is read.
func TestPostgresAllTimeMatchesWindowScan(t *testing.T) {
	s, tracer := testPostgresStoreWithTracer(t)
	ctx := context.Background()
	for _, table := range []string{"provider_earnings", "earnings_summary", "provider_floor_draws", "ledger_entries", "balances"} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}
	seedAllTimeEarnings(t, s)
	epoch := time.Unix(0, 0)

	tracer.reset()
	fast, err := s.NetworkTotals(time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	assertReadsSummaryOnly(t, tracer.snapshot())
	scan, err := s.NetworkTotals(epoch)
	if err != nil {
		t.Fatal(err)
	}
	if fast != scan {
		t.Fatalf("all-time totals %+v != scan %+v", fast, scan)
	}

	for _, metric := range []LeaderboardMetric{LeaderboardEarnings, LeaderboardTokens, LeaderboardJobs} {
		tracer.reset()
		fastRows := s.Leaderboard(metric, time.Time{}, 50)
		assertReadsSummaryOnly(t, tracer.snapshot())
		scanRows := s.Leaderboard(metric, epoch, 50)
		if fastRows == nil || !reflect.DeepEqual(fastRows, scanRows) {
			t.Fatalf("%s: all-time %+v != scan %+v", metric, fastRows, scanRows)
		}
	}
}

func assertReadsSummaryOnly(t *testing.T, events []tracedStatement) {
	t.Helper()
	var summary bool
	for _, e := range events {
		if strings.Contains(e.sql, "FROM provider_earnings") {
			t.Fatalf("all-time path scanned provider_earnings: %s", e.sql)
		}
		if strings.Contains(e.sql, "FROM earnings_summary") {
			summary = true
		}
	}
	if !summary {
		t.Fatalf("all-time path did not read earnings_summary; traced: %v", sqlOf(events))
	}
}

// TestEarningsSummaryBaseRewardBackfill runs the one-shot column backfill on an
// isolated database: history from provider_floor_draws is added to existing
// rows, a missing row is created with the reward as its total, zero-amount
// draws are ignored, a rerun is a no-op, and a leftover queue is drained once.
func TestEarningsSummaryBaseRewardBackfill(t *testing.T) {
	s := newWithdrawableMigrationStore(t, newWithdrawableTestDatabase(t))
	ctx := context.Background()
	for _, q := range []string{
		`CREATE TABLE schema_migrations(id TEXT PRIMARY KEY, applied_at TIMESTAMPTZ DEFAULT NOW())`,
		`CREATE TABLE provider_floor_draws(provider_key TEXT, account_id TEXT, amount_micro_usd BIGINT)`,
		`CREATE TABLE earnings_summary(key TEXT,key_type TEXT,total_count BIGINT,total_micro_usd BIGINT,total_prompt_tokens BIGINT,total_completion_tokens BIGINT,total_base_reward_micro_usd BIGINT NOT NULL DEFAULT 0,updated_at TIMESTAMPTZ,PRIMARY KEY(key,key_type))`,
		earningsSummaryBaseRewardPendingDDL,
		`INSERT INTO provider_floor_draws VALUES ('p1','a',100),('p1','a',50),('p2','a',25),('p3','b',0)`,
		`INSERT INTO earnings_summary VALUES ('a','account',7,1175,70,30,0,NOW()),('p1','provider',7,1150,70,30,0,NOW())`,
	} {
		if _, err := s.pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.migrateEarningsSummaryBaseReward(ctx); err != nil {
		t.Fatal(err)
	}
	assertBaseReward := func(key, keyType string, wantTotal, wantBase int64) {
		t.Helper()
		var total, base int64
		if err := s.pool.QueryRow(ctx, `SELECT total_micro_usd, total_base_reward_micro_usd FROM earnings_summary WHERE key=$1 AND key_type=$2`, key, keyType).Scan(&total, &base); err != nil {
			t.Fatalf("%s/%s: %v", key, keyType, err)
		}
		if total != wantTotal || base != wantBase {
			t.Fatalf("%s/%s total=%d base=%d, want %d/%d", key, keyType, total, base, wantTotal, wantBase)
		}
	}
	assertBaseReward("a", "account", 1175, 175)
	assertBaseReward("p1", "provider", 1150, 150)
	assertBaseReward("p2", "provider", 25, 25)
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM earnings_summary WHERE key IN ('b','p3')`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("zero-amount draws created %d summary rows (err %v)", n, err)
	}
	assertMarkers := func() {
		t.Helper()
		var done bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryBaseRewardMigrationID).Scan(&done); err != nil || !done {
			t.Fatalf("completion marker = %v (err %v), want true", done, err)
		}
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM earnings_summary_base_reward_pending`).Scan(&n); err != nil || n != 0 {
			t.Fatalf("pending queue has %d rows (err %v)", n, err)
		}
	}
	assertMarkers()

	// A restart re-runs the migration: marker present, nothing rescanned.
	if applied, err := s.applyEarningsSummaryBaseRewardMigration(ctx); err != nil || applied {
		t.Fatalf("rerun applied=%v err=%v, want no-op", applied, err)
	}
	assertBaseReward("a", "account", 1175, 175)

	// A crash between the last delta and the completion marker leaves a
	// committed plan with queued keys; resuming applies each exactly once.
	if _, err := s.pool.Exec(ctx, `DELETE FROM schema_migrations WHERE id=$1`, earningsSummaryBaseRewardMigrationID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO earnings_summary_base_reward_pending VALUES ('a','account',5)`); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.applyEarningsSummaryBaseRewardMigration(ctx); err != nil || !applied {
		t.Fatalf("resume applied=%v err=%v", applied, err)
	}
	assertBaseReward("a", "account", 1175, 180)
	assertMarkers()
}

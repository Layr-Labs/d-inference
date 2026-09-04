package store

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func seedEarning(t *testing.T, s Store, account, model string, at time.Time, amount int64) {
	t.Helper()
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: account, ProviderID: "prov", ProviderKey: "key", JobID: uniqueID("job"),
		Model: model, AmountMicroUSD: amount, PromptTokens: 1, CompletionTokens: 1, CreatedAt: at,
	}); err != nil {
		t.Fatalf("RecordProviderEarning: %v", err)
	}
}

// legacySummaryTally is the pre-change /v1/me/summary computation: sum the
// newest-5,000 page in Go. Kept here to document what the page truncated.
func legacySummaryTally(recent []ProviderEarning, now time.Time) (inner, outer AccountEarningsWindow) {
	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)
	for _, e := range recent {
		if e.CreatedAt.After(cutoff7d) {
			outer.Jobs++
			outer.TotalMicroUSD += e.AmountMicroUSD
			if e.CreatedAt.After(cutoff24h) {
				inner.Jobs++
				inner.TotalMicroUSD += e.AmountMicroUSD
			}
		}
	}
	return inner, outer
}

// Both backends return the same nested-window totals: every row of the
// account inside each bound counts (base-reward rows included, other accounts
// and older rows excluded), and an inner window outside the outer is refused.
func TestGetAccountEarningsWindowsParity(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct, other := uniqueID("acct"), uniqueID("acct")
			now := time.Now()
			for i := 0; i < 3; i++ {
				seedEarning(t, s, acct, "model", now.Add(-time.Hour), 100) // inner
			}
			seedEarning(t, s, acct, "base_reward", now.Add(-2*time.Hour), 7) // inner, base reward
			for i := 0; i < 2; i++ {
				seedEarning(t, s, acct, "model", now.Add(-3*24*time.Hour), 10) // outer only
			}
			seedEarning(t, s, acct, "model", now.Add(-10*24*time.Hour), 1) // outside
			seedEarning(t, s, other, "model", now.Add(-time.Hour), 1000)   // other account

			w, err := s.GetAccountEarningsWindows(acct, now.Add(-24*time.Hour), now.Add(-7*24*time.Hour))
			if err != nil {
				t.Fatalf("GetAccountEarningsWindows: %v", err)
			}
			want := AccountEarningsWindows{Inner: AccountEarningsWindow{Jobs: 4, TotalMicroUSD: 307}, Outer: AccountEarningsWindow{Jobs: 6, TotalMicroUSD: 327}}
			if w != want {
				t.Fatalf("windows = %+v, want %+v", w, want)
			}
			if _, err := s.GetAccountEarningsWindows(acct, now.Add(-7*24*time.Hour), now.Add(-24*time.Hour)); err == nil {
				t.Fatal("inner window outside the outer window was accepted")
			}
		})
	}
}

// An account with more rows in a window than the old 5,000-row page: the
// legacy page-and-sum path under-counts both windows; the aggregate is exact.
func TestGetAccountEarningsWindowsExactBeyondPageLimit(t *testing.T) {
	const inner, outerOnly = 5_500, 1_000
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-big")
			now := time.Now()
			if pg, ok := s.(*PostgresStore); ok {
				// Multi-row inserts keep the Postgres variant fast.
				for _, batch := range []struct {
					n   int
					age string
					tag string
				}{{inner, "1 hour", "h"}, {outerOnly, "3 days", "d"}} {
					if _, err := pg.pool.Exec(context.Background(),
						`INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at)
						 SELECT $1, 'prov', 'key', $1 || '-' || $2 || '-' || g, 'model', 3, 1, 1, now() - $3::interval
						   FROM generate_series(1, $4) g`, acct, batch.tag, batch.age, batch.n); err != nil {
						t.Fatalf("seed %s: %v", batch.tag, err)
					}
				}
			} else {
				// Oldest first: the memory store's "newest first" is insertion
				// order, so this mirrors Postgres' created_at DESC page.
				for i := 0; i < outerOnly; i++ {
					seedEarning(t, s, acct, "model", now.Add(-3*24*time.Hour), 3)
				}
				for i := 0; i < inner; i++ {
					seedEarning(t, s, acct, "model", now.Add(-time.Hour), 3)
				}
			}

			// The pre-change path: the newest-5,000 page summed in Go. It caps
			// the outer window at the page size and under-counts the inner one.
			recent, err := s.GetAccountEarnings(acct, 5000)
			if err != nil {
				t.Fatalf("GetAccountEarnings: %v", err)
			}
			legacyInner, legacyOuter := legacySummaryTally(recent, now)
			if legacyOuter.Jobs != 5000 || legacyInner.Jobs >= inner {
				t.Fatalf("legacy tally = inner %+v outer %+v; expected the 5,000-row page to truncate (outer capped at 5000, inner < %d)", legacyInner, legacyOuter, inner)
			}

			w, err := s.GetAccountEarningsWindows(acct, now.Add(-24*time.Hour), now.Add(-7*24*time.Hour))
			if err != nil {
				t.Fatalf("GetAccountEarningsWindows: %v", err)
			}
			want := AccountEarningsWindows{
				Inner: AccountEarningsWindow{Jobs: inner, TotalMicroUSD: 3 * inner},
				Outer: AccountEarningsWindow{Jobs: inner + outerOnly, TotalMicroUSD: 3 * (inner + outerOnly)},
			}
			if w != want {
				t.Fatalf("windows = %+v, want %+v (legacy page gave inner %+v outer %+v)", w, want, legacyInner, legacyOuter)
			}
		})
	}
}

// Batched reputation reads return exactly the providers that have a record.
func TestGetReputationsParity(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ids := make([]string, 4)
			for i := range ids {
				ids[i] = uniqueID(fmt.Sprintf("rep-%d", i))
				if err := s.UpsertProvider(context.Background(), ProviderRecord{ID: ids[i], Hardware: json.RawMessage("{}"), Models: json.RawMessage("[]"), Backend: "mlx", LastSeen: time.Now()}); err != nil {
					t.Fatalf("UpsertProvider: %v", err)
				}
			}
			for i := 0; i < 3; i++ {
				if err := s.UpsertReputation(context.Background(), ids[i], ReputationRecord{TotalJobs: i + 1, SuccessfulJobs: i + 1, ChallengesPassed: 2}); err != nil {
					t.Fatalf("UpsertReputation: %v", err)
				}
			}
			got, err := s.GetReputations(context.Background(), ids)
			if err != nil {
				t.Fatalf("GetReputations: %v", err)
			}
			if len(got) != 3 {
				t.Fatalf("got %d records, want 3: %+v", len(got), got)
			}
			for i := 0; i < 3; i++ {
				if rep, ok := got[ids[i]]; !ok || rep.TotalJobs != i+1 || rep.ChallengesPassed != 2 {
					t.Fatalf("reputation[%s] = %+v (present=%v)", ids[i], rep, ok)
				}
			}
			if _, ok := got[ids[3]]; ok {
				t.Fatal("provider without a record appeared in the batch result")
			}
			empty, err := s.GetReputations(context.Background(), nil)
			if err != nil || len(empty) != 0 {
				t.Fatalf("empty id list: %+v, %v", empty, err)
			}
		})
	}
}

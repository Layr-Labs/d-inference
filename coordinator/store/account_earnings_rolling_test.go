package store

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// seedAccountEarnings inserts n rows for accountID spread evenly over the
// last 7 d (the newest 1/7 of them inside the last 24 h). Postgres rows go in
// as one multi-row statement so 6,000 of them do not cost 6,000 round trips.
func seedAccountEarnings(t *testing.T, st Store, accountID string, n int, now time.Time) (want AccountEarningsWindows) {
	t.Helper()
	span := 7 * 24 * time.Hour
	rows := make([]ProviderEarning, 0, n)
	for i := range n {
		// i=0 is the oldest (just inside 7 d), i=n-1 the newest.
		age := span - time.Duration(i+1)*span/time.Duration(n+1)
		createdAt := now.Add(-age)
		amount := int64(100 + i%7)
		rows = append(rows, ProviderEarning{
			AccountID: accountID, ProviderID: "node-" + accountID, ProviderKey: "key-" + accountID,
			JobID: fmt.Sprintf("%s-job-%05d", accountID, i), Model: "model",
			AmountMicroUSD: amount, PromptTokens: 1, CompletionTokens: 2, CreatedAt: createdAt,
		})
		want.Last7dJobs++
		want.Last7dMicroUSD += amount
		if !createdAt.Before(now.Add(-24 * time.Hour)) {
			want.Last24hJobs++
			want.Last24hMicroUSD += amount
		}
	}
	// One row just outside the 7 d window must never count.
	rows = append(rows, ProviderEarning{
		AccountID: accountID, ProviderID: "node-" + accountID, ProviderKey: "key-" + accountID,
		JobID: accountID + "-job-stale", Model: "model", AmountMicroUSD: 1_000_000,
		CreatedAt: now.Add(-span - time.Minute),
	})

	if pg, ok := st.(*PostgresStore); ok {
		accounts := make([]string, len(rows))
		providers := make([]string, len(rows))
		keys := make([]string, len(rows))
		jobs := make([]string, len(rows))
		models := make([]string, len(rows))
		amounts := make([]int64, len(rows))
		prompts := make([]int32, len(rows))
		completions := make([]int32, len(rows))
		created := make([]time.Time, len(rows))
		for i, r := range rows {
			accounts[i], providers[i], keys[i], jobs[i], models[i] = r.AccountID, r.ProviderID, r.ProviderKey, r.JobID, r.Model
			amounts[i], prompts[i], completions[i], created[i] = r.AmountMicroUSD, int32(r.PromptTokens), int32(r.CompletionTokens), r.CreatedAt
		}
		if _, err := pg.pool.Exec(context.Background(),
			`INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at)
			 SELECT * FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::bigint[], $7::int[], $8::int[], $9::timestamptz[])`,
			accounts, providers, keys, jobs, models, amounts, prompts, completions, created,
		); err != nil {
			t.Fatalf("seed earnings: %v", err)
		}
		return want
	}
	for i := range rows {
		if err := st.RecordProviderEarning(&rows[i]); err != nil {
			t.Fatalf("seed earnings: %v", err)
		}
	}
	return want
}

// TestAccountEarningsWindowsExactBeyondPageLimit: an account with 6,000 rows
// in the last 7 d gets exact window figures from the aggregate, while the row
// page the dashboard used to sum stops at 5,000; memory and postgres agree.
func TestAccountEarningsWindowsExactBeyondPageLimit(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	results := map[string]AccountEarningsWindows{}
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("acct-windows")
			want := seedAccountEarnings(t, st, account, 6_000, now)

			got, err := st.AccountEarningsWindows(account, now)
			if err != nil {
				t.Fatalf("AccountEarningsWindows: %v", err)
			}
			if got != want {
				t.Fatalf("windows = %+v, want %+v", got, want)
			}
			if got.Last7dJobs != 6_000 {
				t.Fatalf("Last7dJobs = %d, want 6000", got.Last7dJobs)
			}
			results[name] = got

			// The old path: a 5,000-row page can never see all 6,000 rows.
			page, err := st.GetAccountEarnings(account, 5000)
			if err != nil {
				t.Fatalf("GetAccountEarnings: %v", err)
			}
			if len(page) != 5000 {
				t.Fatalf("page = %d rows, want the 5,000-row truncation the aggregate replaces", len(page))
			}

			// Another account's rows are invisible.
			other, err := st.AccountEarningsWindows(uniqueID("acct-none"), now)
			if err != nil || other != (AccountEarningsWindows{}) {
				t.Fatalf("unknown account windows = %+v, %v; want zeros", other, err)
			}
		})
	}
	if pg, ok := results["postgres"]; ok && pg != results["memory"] {
		t.Fatalf("memory/postgres parity: memory %+v, postgres %+v", results["memory"], pg)
	}
}

// TestGetReputationsBatch: one lookup returns every known ID and skips the
// unknown ones; an empty ID list makes no query.
func TestGetReputationsBatch(t *testing.T) {
	ctx := context.Background()
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ids := make([]string, 0, 21)
			for i := range 20 {
				id := uniqueID(fmt.Sprintf("rep-%02d", i))
				ids = append(ids, id)
				// provider_reputation references providers(id).
				if err := st.UpsertProvider(ctx, ProviderRecord{
					ID: id, Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "mlx-swift",
				}); err != nil {
					t.Fatalf("upsert provider: %v", err)
				}
				if err := st.UpsertReputation(ctx, id, ReputationRecord{
					TotalJobs: 10 + i, SuccessfulJobs: 9 + i, FailedJobs: 1,
					TotalUptimeSeconds: int64(100 * i), AvgResponseTimeMs: int64(50 + i),
					ChallengesPassed: i, ChallengesFailed: 0,
				}); err != nil {
					t.Fatalf("upsert reputation: %v", err)
				}
			}
			ids = append(ids, uniqueID("rep-unknown"))

			reps, err := st.GetReputations(ctx, ids)
			if err != nil {
				t.Fatalf("GetReputations: %v", err)
			}
			if len(reps) != 20 {
				t.Fatalf("reputations = %d, want 20 (unknown id absent)", len(reps))
			}
			for i, id := range ids[:20] {
				rep := reps[id]
				if rep == nil {
					t.Fatalf("missing reputation for %s", id)
				}
				single, err := st.GetReputation(ctx, id)
				if err != nil {
					t.Fatalf("GetReputation: %v", err)
				}
				if *rep != *single || rep.TotalJobs != 10+i {
					t.Fatalf("batch %+v != single %+v for %s", *rep, *single, id)
				}
			}
			if _, ok := reps[ids[20]]; ok {
				t.Fatal("unknown id returned a reputation")
			}

			empty, err := st.GetReputations(ctx, nil)
			if err != nil || len(empty) != 0 {
				t.Fatalf("empty lookup = %v, %v; want empty map, nil", empty, err)
			}
		})
	}
}

package postgres

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestRecordProviderEarningMaintainsSummaryWithoutRestart: a retried
// earning (same job_id) updates the account summary exactly once, live, and
// never touches balances.
func TestRecordProviderEarningMaintainsSummaryWithoutRestart(t *testing.T) {
	s := testPostgresStore(t)
	e := &store.ProviderEarning{AccountID: uniqueID("account"), ProviderKey: uniqueID("key"), ProviderID: "p", JobID: uniqueID("job"), Model: "m", AmountMicroUSD: 100, PromptTokens: 20, CompletionTokens: 30}
	for i := 0; i < 2; i++ {
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatal(err)
		}
	}
	var count, money, prompt, completion int64
	if err := s.pool.QueryRow(context.Background(), `SELECT total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens FROM earnings_summary WHERE key=$1 AND key_type='account'`, e.AccountID).Scan(&count, &money, &prompt, &completion); err != nil {
		t.Fatal(err)
	}
	if count != 1 || money != 100 || prompt != 20 || completion != 30 {
		t.Fatalf("summary doubled/lost: %d %d %d %d", count, money, prompt, completion)
	}
	var balanceRows int
	if err := s.pool.QueryRow(context.Background(), `SELECT count(*) FROM balances WHERE account_id=$1`, e.AccountID).Scan(&balanceRows); err != nil || balanceRows != 0 {
		t.Fatalf("record-only unexpectedly credited balance: %d %v", balanceRows, err)
	}
}

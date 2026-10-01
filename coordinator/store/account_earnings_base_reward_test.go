package store

import (
	"fmt"
	"testing"
	"time"
)

// TestAccountEarningsWindowsBaseRewardRowsAreNotJobs: the window job counts
// cover inference rows only, while the micro-USD sums keep base rewards; memory
// and postgres agree.
func TestAccountEarningsWindowsBaseRewardRowsAreNotJobs(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	results := map[string]AccountEarningsWindows{}
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("acct-base-reward")
			type seed struct {
				model  string
				age    time.Duration
				amount int64
			}
			seeds := []seed{
				// Inference rows: two inside 24 h, one only inside 7 d.
				{"model", 1 * time.Hour, 100},
				{"model", 5 * time.Hour, 200},
				{"model", 3 * 24 * time.Hour, 400},
				// Base reward rows: three inside 24 h, two only inside 7 d.
				{"base_reward", 2 * time.Hour, 1_000},
				{"base_reward", 6 * time.Hour, 2_000},
				{"base_reward", 12 * time.Hour, 4_000},
				{"base_reward", 2 * 24 * time.Hour, 8_000},
				{"base_reward", 5 * 24 * time.Hour, 16_000},
				// Outside the 7 d window: never counted.
				{"model", 8 * 24 * time.Hour, 32_000},
				{"base_reward", 8 * 24 * time.Hour, 64_000},
			}
			for i, s := range seeds {
				if err := st.RecordProviderEarning(&ProviderEarning{
					AccountID: account, ProviderID: "node-" + account, ProviderKey: "key-" + account,
					JobID: fmt.Sprintf("%s-row-%02d", account, i), Model: s.model,
					AmountMicroUSD: s.amount, CreatedAt: now.Add(-s.age),
				}); err != nil {
					t.Fatalf("seed earnings: %v", err)
				}
			}

			got, err := st.AccountEarningsWindows(account, now)
			if err != nil {
				t.Fatalf("AccountEarningsWindows: %v", err)
			}
			want := AccountEarningsWindows{
				Last24hJobs: 2, Last24hMicroUSD: 100 + 200 + 1_000 + 2_000 + 4_000,
				Last7dJobs: 3, Last7dMicroUSD: 100 + 200 + 400 + 1_000 + 2_000 + 4_000 + 8_000 + 16_000,
			}
			if got != want {
				t.Fatalf("windows = %+v, want %+v (jobs exclude base_reward, micro-USD includes it)", got, want)
			}
			results[name] = got
		})
	}
	if pg, ok := results["postgres"]; ok && pg != results["memory"] {
		t.Fatalf("memory/postgres parity: memory %+v, postgres %+v", results["memory"], pg)
	}
}

package network

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store supplies only the aggregate queries exposed by public network views.
// Each persistence backend retains its existing timeouts and transactions.
type Store interface {
	UsageTotals() (store.UsageTotals, error)
	UsageTotalsSince(time.Time) (store.UsageTotals, error)
	UsageTimeSeries(time.Time, time.Time, time.Duration) ([]store.UsageBucket, error)
	UsageCountSince(time.Time) (int64, error)
	UsageLocationBuckets(time.Time) ([]store.UsageLocationBucket, error)
	UsageFlowBuckets(time.Time, map[string]*store.ProviderLocation) ([]store.UsageFlowBucket, error)
	Leaderboard(store.LeaderboardMetric, time.Time, int) []store.LeaderboardRow
	NetworkTotals(time.Time) (store.NetworkTotalsRow, error)
}
